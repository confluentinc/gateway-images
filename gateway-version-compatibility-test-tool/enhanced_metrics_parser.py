#!/usr/bin/env python3
"""
Enhanced Kroxylicious Compatibility Test Metrics Parser
Parses Prometheus metrics to generate compatibility reports with per-virtual-cluster balance checking
"""

import csv
import json
import os
import re
import requests
import sys
import time
from collections import defaultdict
from datetime import datetime

from api_keys import KAFKA_API_KEYS, get_api_key_int


class EnhancedKroxyliciousMetricsParser:
  def __init__(self, metrics_url="http://localhost:9190/metrics"):
    self.metrics_url = metrics_url
    self.results = []

  def scrape_metrics(self):
    """Scrape current metrics from Kroxylicious"""
    try:
      response = requests.get(self.metrics_url, timeout=10)
      response.raise_for_status()
      return response.text
    except Exception as e:
      print(f"Error scraping metrics: {e}")
      return None

  def parse_metrics_file(self, file_path):
    """Parse metrics from a file instead of URL"""
    try:
      with open(file_path, 'r') as f:
        return f.read()
    except Exception as e:
      print(f"Error reading metrics file {file_path}: {e}")
      return None

  def parse_api_usage(self, metrics_text, client_version, server_version, test_name):
    """Extract API usage data from metrics with per-virtual-cluster balance checking"""
    api_data = {}
    
    # Parse all 4 metrics with virtual cluster and node_id information
    patterns = {
        'client_to_proxy_requests': r'kroxylicious_client_to_proxy_request_total\{api_key="([^"]*)",api_version="([^"]*)",decoded="[^"]*",node_id="([^"]*)",virtual_cluster="([^"]*)"\} ([0-9.]+)',
        'proxy_to_server_requests': r'kroxylicious_proxy_to_server_request_total\{api_key="([^"]*)",api_version="([^"]*)",decoded="[^"]*",node_id="([^"]*)",virtual_cluster="([^"]*)"\} ([0-9.]+)',
        'server_to_proxy_responses': r'kroxylicious_server_to_proxy_response_total\{api_key="([^"]*)",api_version="([^"]*)",decoded="[^"]*",node_id="([^"]*)",virtual_cluster="([^"]*)"\} ([0-9.]+)',
        'proxy_to_client_responses': r'kroxylicious_proxy_to_client_response_total\{api_key="([^"]*)",api_version="([^"]*)",decoded="[^"]*",node_id="([^"]*)",virtual_cluster="([^"]*)"\} ([0-9.]+)'
    }
    
    # Parse all metrics and aggregate by API+virtual_cluster
    metrics = {}
    for metric_type, pattern in patterns.items():
        matches = re.findall(pattern, metrics_text)
        for api_key, api_version, node_id, virtual_cluster, count in matches:
            key = f"{api_key}_{api_version}_{virtual_cluster}"
            if key not in metrics:
                metrics[key] = {
                    'api_key': api_key,
                    'api_version': api_version,
                    'virtual_cluster': virtual_cluster,
                    'client_to_proxy_requests': 0,
                    'proxy_to_server_requests': 0,
                    'server_to_proxy_responses': 0,
                    'proxy_to_client_responses': 0
                }
            metrics[key][metric_type] += float(count)
    
    # Process each API+virtual_cluster combination
    for key, data in metrics.items():
        api_key_int = get_api_key_int(data['api_key'])
        
        # Calculate totals
        total_requests = (data['client_to_proxy_requests'] + 
                         data['proxy_to_server_requests'])
        total_responses = (data['server_to_proxy_responses'] + 
                          data['proxy_to_client_responses'])
        
        # Balance check: requests should equal responses
        if total_requests == total_responses and total_requests > 0:
            status = 'SUCCESS'
            client_errors = 0
            upstream_errors = 0
        elif total_requests > 0:
            status = 'ERROR'  # Imbalanced - some requests didn't get responses
            # Calculate how many requests failed
            failed_requests = total_requests - total_responses
            client_errors = failed_requests  # Assume client-side issues
            upstream_errors = 0
        else:
            status = 'NO_TRAFFIC'
            client_errors = 0
            upstream_errors = 0
        
        # Create result record
        result_key = f"{data['api_key']}_{data['api_version']}_{data['virtual_cluster']}"
        api_data[result_key] = {
            'api_key': data['api_key'],
            'api_key_int': api_key_int,
            'api_version': data['api_version'],
            'virtual_cluster': data['virtual_cluster'],
            'request_count': total_requests,
            'response_count': total_responses,
            'client_errors': client_errors,
            'upstream_errors': upstream_errors,
            'status': status,
            'client_version': client_version,
            'server_version': server_version,
            'test_name': test_name,
            'timestamp': datetime.now().isoformat(),
            # Detailed breakdown for debugging
            'client_to_proxy_requests': data['client_to_proxy_requests'],
            'proxy_to_server_requests': data['proxy_to_server_requests'],
            'server_to_proxy_responses': data['server_to_proxy_responses'],
            'proxy_to_client_responses': data['proxy_to_client_responses']
        }
    
    return api_data

  def process_results_directory(self, results_dir):
    """Process all metrics files in a results directory"""
    print(f"Processing results directory: {results_dir}")

    metrics_files = [f for f in os.listdir(results_dir) if
                     f.endswith('_metrics.txt')]
    print(f"Found {len(metrics_files)} metrics files")

    for metrics_file in sorted(metrics_files):
      file_path = os.path.join(results_dir, metrics_file)
      print(f"Processing: {metrics_file}")

      # Extract version info from filename
      # Format: java7.4.0_server7.4.0_metrics.txt
      match = re.match(r'java([^_]+)_server([^_]+)_metrics\.txt',
                       metrics_file)
      if not match:
        print(f"Warning: Could not parse version info from {metrics_file}")
        continue

      client_version = match.group(1)
      server_version = match.group(2)

      # Parse metrics
      metrics_text = self.parse_metrics_file(file_path)
      if not metrics_text:
        continue

      api_data = self.parse_api_usage(metrics_text, client_version,
                                      server_version, metrics_file)

      # Add to results
      for data in api_data.values():
        self.results.append(data)

    print(f"Processed {len(self.results)} API usage records")

  def generate_compatibility_matrix(self):
    """Generate compatibility matrix from results with virtual cluster breakdown"""
    matrix = defaultdict(lambda: {
      'apis': set(),
      'api_ints': set(),
      'api_versions': set(),
      'virtual_clusters': set(),
      'total_requests': 0,
      'total_responses': 0,
      'total_client_errors': 0,
      'total_upstream_errors': 0,
      'successful_apis': set(),
      'failed_apis': set(),
      'virtual_cluster_breakdown': defaultdict(lambda: {
        'total_requests': 0,
        'total_responses': 0,
        'successful_apis': set(),
        'failed_apis': set()
      })
    })

    for result in self.results:
      key = f"{result['client_version']}-{result['server_version']}"
      vc_key = result['virtual_cluster']
      
      matrix[key]['apis'].add(result['api_key'])
      matrix[key]['api_ints'].add(str(result['api_key_int']))
      matrix[key]['api_versions'].add(result['api_version'])
      matrix[key]['virtual_clusters'].add(vc_key)
      matrix[key]['total_requests'] += result['request_count']
      matrix[key]['total_responses'] += result['response_count']
      matrix[key]['total_client_errors'] += result['client_errors']
      matrix[key]['total_upstream_errors'] += result['upstream_errors']

      # Update virtual cluster breakdown
      matrix[key]['virtual_cluster_breakdown'][vc_key]['total_requests'] += result['request_count']
      matrix[key]['virtual_cluster_breakdown'][vc_key]['total_responses'] += result['response_count']

      if result['status'] == 'SUCCESS':
        matrix[key]['successful_apis'].add(
          f"{result['api_key']}({result['api_key_int']})")
        matrix[key]['virtual_cluster_breakdown'][vc_key]['successful_apis'].add(
          f"{result['api_key']}({result['api_key_int']})")
      elif result['status'] == 'ERROR':
        matrix[key]['failed_apis'].add(
          f"{result['api_key']}({result['api_key_int']})")
        matrix[key]['virtual_cluster_breakdown'][vc_key]['failed_apis'].add(
          f"{result['api_key']}({result['api_key_int']})")

    return matrix

  def _generate_detailed_csv(self, output_dir):
    """Generate detailed CSV report"""
    csv_file = os.path.join(output_dir, "detailed_api_usage.csv")
    with open(csv_file, 'w', newline='') as f:
      fieldnames = ['api_key', 'api_key_int', 'api_version', 'virtual_cluster', 
                    'client_version', 'server_version', 'request_count', 'response_count',
                    'client_errors', 'upstream_errors', 'status', 'test_name', 'timestamp',
                    'client_to_proxy_requests', 'proxy_to_server_requests',
                    'server_to_proxy_responses', 'proxy_to_client_responses']
      writer = csv.DictWriter(f, fieldnames=fieldnames)
      writer.writeheader()
      writer.writerows(self.results)
    return csv_file

  def _generate_summary_report(self, output_dir, matrix):
    """Generate summary report"""
    summary_file = os.path.join(output_dir, "compatibility_summary.txt")
    with open(summary_file, 'w') as f:
      f.write("KAFKA CLIENT-SERVER COMPATIBILITY MATRIX\n")
      f.write("=" * 60 + "\n\n")
      
      for key, data in sorted(matrix.items()):
        client_ver, server_ver = key.split('-')
        f.write(f"CLIENT: {client_ver} | SERVER: {server_ver}\n")
        f.write("-" * 40 + "\n")
        
        # Overall summary
        total_errors = data['total_client_errors'] + data['total_upstream_errors']
        if data['total_requests'] > 0 and total_errors == 0:
          overall_status = "✅ PASS"
        elif data['total_requests'] > 0 and total_errors > 0:
          overall_status = "❌ FAIL"
        else:
          overall_status = "⚠️ NO_DATA"
        
        f.write(f"OVERALL STATUS: {overall_status}\n")
        f.write(f"Total Requests: {int(data['total_requests'])} | Total Responses: {int(data['total_responses'])} | Errors: {int(total_errors)}\n")
        f.write(f"Successful APIs: {len(data['successful_apis'])} | Failed APIs: {len(data['failed_apis'])}\n\n")
        
        # Virtual cluster breakdown
        f.write("CLIENT AUTHENTICATION MODES:\n")
        f.write("-" * 30 + "\n")
        
        for vc_name, vc_data in data['virtual_cluster_breakdown'].items():
          # Determine virtual cluster type
          if 'sasl' in vc_name:
            vc_type = "SASL"
          elif 'ssl' in vc_name:
            vc_type = "SSL"
          else:
            vc_type = "PLAINTEXT"
          
          vc_errors = vc_data['total_requests'] - vc_data['total_responses']
          if vc_data['total_requests'] > 0 and vc_errors == 0:
            vc_status = "✅ PASS"
          elif vc_data['total_requests'] > 0 and vc_errors > 0:
            vc_status = "❌ FAIL"
          else:
            vc_status = "⚠️ NO_DATA"
          
          f.write(f"  {vc_type:<12} | {vc_status} | Requests: {int(vc_data['total_requests']):<6} | Responses: {int(vc_data['total_responses']):<6} | Errors: {int(vc_errors):<4} | Success: {len(vc_data['successful_apis']):<3} | Failed: {len(vc_data['failed_apis'])}\n")
        
        f.write("\n")
        
        # Detailed API breakdown
        if data['failed_apis']:
          f.write("FAILED APIs:\n")
          for api in sorted(data['failed_apis']):
            f.write(f"  ❌ {api}\n")
          f.write("\n")
        
        if data['successful_apis']:
          f.write("SUCCESSFUL APIs:\n")
          for api in sorted(data['successful_apis']):
            f.write(f"  ✅ {api}\n")
          f.write("\n")
        
        f.write("=" * 60 + "\n\n")
    
    return summary_file

  def _generate_api_reference(self, output_dir):
    """Generate API key reference file"""
    api_ref_file = os.path.join(output_dir, "api_key_reference.txt")
    with open(api_ref_file, 'w') as f:
      f.write("KAFKA API KEY REFERENCE\n")
      f.write("=" * 30 + "\n\n")
      for api_name, api_int in sorted(KAFKA_API_KEYS.items()):
        f.write(f"{api_name:<30} -> {api_int}\n")
    return api_ref_file

  def generate_reports(self, output_dir):
    """Generate all reports"""
    os.makedirs(output_dir, exist_ok=True)

    # Generate compatibility matrix
    matrix = self.generate_compatibility_matrix()

    # Generate detailed CSV
    csv_file = self._generate_detailed_csv(output_dir)
    print(f"Generated detailed CSV: {csv_file}")

    # Generate summary report
    summary_file = self._generate_summary_report(output_dir, matrix)
    print(f"Generated summary report: {summary_file}")

    # Generate API reference
    api_ref_file = self._generate_api_reference(output_dir)
    print(f"Generated API reference: {api_ref_file}")

    # Generate enhanced JSON report
    json_file = self._generate_enhanced_json_report(output_dir, matrix)
    print(f"Generated enhanced JSON report: {json_file}")

    return {
      'csv_file': csv_file,
      'summary_file': summary_file,
      'api_ref_file': api_ref_file,
      'json_file': json_file
    }

  def _generate_enhanced_json_report(self, output_dir, matrix):
    """Generate enhanced JSON report with test matrix info and virtual cluster breakdown"""
    json_file = os.path.join(output_dir, "compatibility_report.json")
    
    # Calculate test matrix info
    client_versions = set()
    server_versions = set()
    for result in self.results:
      client_versions.add(result['client_version'])
      server_versions.add(result['server_version'])
    
    total_expected_combinations = len(client_versions) * len(server_versions)
    tested_combinations = len(matrix)
    missing_combinations = total_expected_combinations - tested_combinations
    
    # Calculate overall compatibility percentage
    passed_tests = sum(1 for data in matrix.values() 
                      if data['total_requests'] > 0 and 
                      (data['total_client_errors'] + data['total_upstream_errors']) == 0)
    total_tests = len([data for data in matrix.values() if data['total_requests'] > 0])
    compatibility_percentage = (passed_tests / total_tests * 100) if total_tests > 0 else 0
    
    # Calculate test summary
    passed_tests_count = sum(1 for data in matrix.values() 
                           if data['total_requests'] > 0 and 
                           (data['total_client_errors'] + data['total_upstream_errors']) == 0)
    failed_tests_count = sum(1 for data in matrix.values() 
                           if data['total_requests'] > 0 and 
                           (data['total_client_errors'] + data['total_upstream_errors']) > 0)
    no_data_tests = sum(1 for data in matrix.values() if data['total_requests'] == 0)
    total_api_calls = sum(data['total_requests'] for data in matrix.values())
    
    # Convert matrix data for JSON serialization
    enhanced_matrix = {}
    for k, v in matrix.items():
      client_ver, server_ver = k.split('-')
      
      # Determine status
      total_errors = v['total_client_errors'] + v['total_upstream_errors']
      if v['total_requests'] > 0 and total_errors == 0:
        status = "PASS"
        status_emoji = "✅"
      elif v['total_requests'] > 0 and total_errors > 0:
        status = "FAIL"
        status_emoji = "❌"
      else:
        status = "NO_DATA"
        status_emoji = "⚠️"
      
      # Convert virtual cluster breakdown to serializable format
      vc_breakdown = {}
      for vc_name, vc_data in v['virtual_cluster_breakdown'].items():
        vc_breakdown[vc_name] = {
          'total_requests': vc_data['total_requests'],
          'total_responses': vc_data['total_responses'],
          'successful_apis': list(vc_data['successful_apis']),
          'failed_apis': list(vc_data['failed_apis'])
        }
      
      enhanced_matrix[k] = {
        **v, 
        'apis': list(v['apis']), 
        'api_ints': list(v['api_ints']),
        'api_versions': list(v['api_versions']),
        'virtual_clusters': list(v['virtual_clusters']),
        'successful_apis': list(v['successful_apis']),
        'failed_apis': list(v['failed_apis']),
        'virtual_cluster_breakdown': vc_breakdown,
        'client_version': client_ver,
        'server_version': server_ver,
        'status': status,
        'status_emoji': status_emoji,
        'compatibility_score': 100 if status == "PASS" else (50 if status == "NO_DATA" else 0)
      }
    
    report_data = {
      'test_timestamp': datetime.now().isoformat(),
      'test_matrix_info': {
        'total_expected_combinations': total_expected_combinations,
        'tested_combinations': tested_combinations,
        'missing_combinations': missing_combinations,
        'client_versions': sorted(list(client_versions)),
        'server_versions': sorted(list(server_versions)),
        'compatibility_percentage': round(compatibility_percentage, 1)
      },
      'test_summary': {
        'passed_tests': passed_tests_count,
        'failed_tests': failed_tests_count,
        'no_data_tests': no_data_tests,
        'missing_tests': missing_combinations,
        'total_api_calls': int(total_api_calls)
      },
      'matrix_results': enhanced_matrix,
      'api_key_mapping': KAFKA_API_KEYS
    }
    
    with open(json_file, 'w') as f:
      json.dump(report_data, f, indent=2)
    
    return json_file


def main():
  if len(sys.argv) != 2:
    print("Usage: python3 enhanced_metrics_parser.py <results_directory>")
    sys.exit(1)

  results_dir = sys.argv[1]
  if not os.path.exists(results_dir):
    print(f"Error: Results directory {results_dir} does not exist")
    sys.exit(1)

  parser = EnhancedKroxyliciousMetricsParser()
  parser.process_results_directory(results_dir)

  if not parser.results:
    print("No results found to process")
    sys.exit(1)

  # Generate reports
  output_dir = os.path.join(results_dir, "reports")
  reports = parser.generate_reports(output_dir)

  print(f"\nReports generated in: {output_dir}")
  for report_type, report_path in reports.items():
    print(f"  {report_type}: {report_path}")


if __name__ == "__main__":
  main()