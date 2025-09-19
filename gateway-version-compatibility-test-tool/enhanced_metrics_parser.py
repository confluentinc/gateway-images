#!/usr/bin/env python3
"""
Enhanced Kroxylicious Compatibility Test Metrics Parser
Parses Prometheus metrics to generate compatibility reports with integer API keys
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

  def parse_api_usage(self, metrics_text, client_version, server_version,
      test_name):
    """Extract API usage data from metrics with integer API keys"""
    api_data = {}

    # Parse client-to-proxy requests
    request_pattern = r'kroxylicious_client_to_proxy_request_total\{.*api_key="([^"]*)".*api_version="([^"]*)".*\} ([0-9.]+)'
    requests_matches = re.findall(request_pattern, metrics_text)

    for api_key_name, api_version, count in requests_matches:
      # Convert API key to integer
      api_key_int = get_api_key_int(api_key_name)

      key = f"{api_key_name}_{api_version}"
      api_data[key] = {
        'api_key': api_key_name,
        'api_key_int': api_key_int,
        'api_version': api_version,
        'request_count': float(count),
        'client_version': client_version,
        'server_version': server_version,
        'test_name': test_name,
        'timestamp': datetime.now().isoformat()
      }

    # Parse error counts - more comprehensive
    client_error_patterns = [
      r'kroxylicious_client_to_proxy_errors_total\{.*\} ([0-9.]+)',
      r'kroxylicious_client_connection_failures_total\{.*\} ([0-9.]+)'
    ]

    total_client_errors = 0
    for pattern in client_error_patterns:
      error_matches = re.findall(pattern, metrics_text)
      total_client_errors += sum(float(e) for e in error_matches)

    # Parse upstream errors
    upstream_error_patterns = [
      r'kroxylicious_upstream_connection_failures_total\{.*\} ([0-9.]+)',
      r'kroxylicious_proxy_to_upstream_errors_total\{.*\} ([0-9.]+)'
    ]

    total_upstream_errors = 0
    for pattern in upstream_error_patterns:
      error_matches = re.findall(pattern, metrics_text)
      total_upstream_errors += sum(float(e) for e in error_matches)

    # Add error info to each API
    for key in api_data:
      api_data[key]['client_errors'] = total_client_errors
      api_data[key]['upstream_errors'] = total_upstream_errors

      # Determine status
      if total_client_errors == 0 and total_upstream_errors == 0 and \
          api_data[key]['request_count'] > 0:
        api_data[key]['status'] = 'SUCCESS'
      elif total_client_errors > 0 or total_upstream_errors > 0:
        api_data[key]['status'] = 'ERROR'
      else:
        api_data[key]['status'] = 'NO_TRAFFIC'

    return api_data

  def parse_status_file(self, file_path, client_version, server_version, test_name):
    """Parse status file to create entry for failed tests"""
    try:
      with open(file_path, 'r') as f:
        status_content = f.read().strip()
      
      # Parse status file content
      lines = status_content.split('\n')
      status_info = {}
      for line in lines:
        if ':' in line:
          key, value = line.split(':', 1)
          status_info[key.strip()] = value.strip()
      
      # Determine the failure type and status
      failure_type = status_info.get('FAILURE_TYPE', 'UNKNOWN')
      status_message = status_info.get('SETUP_FAILED', status_info.get('SETUP_SUCCESS', 'Unknown status'))
      
      # Create a result entry for the failed test
      result = {
        'api_key': 'N/A',
        'api_key_int': -1,  # Use -1 to indicate failed setup
        'api_version': 'N/A',
        'request_count': 0,
        'client_version': client_version,
        'server_version': server_version,
        'test_name': test_name,
        'timestamp': status_info.get('TIMESTAMP', datetime.now().isoformat()),
        'client_errors': 0,
        'upstream_errors': 0,
        'failure_type': failure_type,
        'status_message': status_message
      }
      
      # Set status based on failure type
      if failure_type == 'NONE':
        result['status'] = 'SUCCESS'
      else:
        result['status'] = 'SETUP_FAILED'
      
      return result
      
    except Exception as e:
      print(f"Error parsing status file {file_path}: {e}")
      return None

  def process_results_directory(self, results_dir):
    """Process all metrics files and status files in a results directory"""
    print(f"Processing results directory: {results_dir}")

    # Find both metrics and status files
    metrics_files = [f for f in os.listdir(results_dir) if
                     f.endswith('_metrics.txt')]
    status_files = [f for f in os.listdir(results_dir) if
                    f.endswith('_status.txt')]
    
    print(f"Found {len(metrics_files)} metrics files and {len(status_files)} status files")

    # Process metrics files (successful tests)
    for metrics_file in sorted(metrics_files):
      file_path = os.path.join(results_dir, metrics_file)

      # Extract test info from filename
      # Expected format: java3.6_server3.8_metrics.txt
      base_name = metrics_file.replace('_metrics.txt', '')
      if 'java' in base_name and 'server' in base_name:
        parts = base_name.split('_')
        client_part = [p for p in parts if p.startswith('java')]
        server_part = [p for p in parts if p.startswith('server')]

        if client_part and server_part:
          client_version = client_part[0].replace('java', '')
          server_version = server_part[0].replace('server', '')

          print(
            f"Processing: {metrics_file} -> Client: {client_version}, Server: {server_version}")

          # Parse metrics file
          metrics_text = self.parse_metrics_file(file_path)
          if metrics_text:
            api_data = self.parse_api_usage(metrics_text, client_version,
                                            server_version, base_name)
            self.results.extend(api_data.values())
            print(f"  Found {len(api_data)} API calls")
          else:
            print(f"  Failed to parse {metrics_file}")
        else:
          print(
            f"  Skipping {metrics_file} - couldn't parse client/server versions")
      else:
        print(f"  Skipping {metrics_file} - not a test metrics file")

    # Process status files (including failed tests)
    for status_file in sorted(status_files):
      file_path = os.path.join(results_dir, status_file)
      
      # Extract test info from filename  
      # Expected format: java3.6_server3.8_status.txt
      base_name = status_file.replace('_status.txt', '')
      if 'java' in base_name and 'server' in base_name:
        parts = base_name.split('_')
        client_part = [p for p in parts if p.startswith('java')]
        server_part = [p for p in parts if p.startswith('server')]

        if client_part and server_part:
          client_version = client_part[0].replace('java', '')
          server_version = server_part[0].replace('server', '')

          # Check if we already processed metrics for this combination
          existing_result = any(r['client_version'] == client_version and 
                              r['server_version'] == server_version 
                              for r in self.results)
          
          if not existing_result:
            # Process failed test status
            print(f"Processing failed test: {status_file} -> Client: {client_version}, Server: {server_version}")
            status_data = self.parse_status_file(file_path, client_version, server_version, base_name)
            if status_data:
              self.results.append(status_data)
              print(f"  Added failed test entry")
          else:
            print(f"  Skipping {status_file} - already have metrics data for this combination")

  def _build_matrix_data(self):
    """Build matrix data structure from results"""
    matrix = defaultdict(lambda: {
      'apis': set(),
      'api_ints': set(),
      'api_versions': set(),
      'total_requests': 0,
      'total_client_errors': 0,
      'total_upstream_errors': 0,
      'successful_apis': set(),
      'failed_apis': set(),
      'setup_status': 'UNKNOWN',
      'failure_type': None,
      'status_message': None
    })

    for result in self.results:
      key = f"{result['client_version']}-{result['server_version']}"
      
      # Handle setup failed results differently
      if result['status'] == 'SETUP_FAILED':
        matrix[key]['setup_status'] = 'SETUP_FAILED'
        matrix[key]['failure_type'] = result.get('failure_type', 'UNKNOWN')
        matrix[key]['status_message'] = result.get('status_message', 'Setup failed')
        # Don't add API data for failed setups
        continue
      
      matrix[key]['apis'].add(result['api_key'])
      matrix[key]['api_ints'].add(str(result['api_key_int']))
      matrix[key]['api_versions'].add(result['api_version'])
      matrix[key]['total_requests'] += result['request_count']
      matrix[key]['total_client_errors'] = result['client_errors']
      matrix[key]['total_upstream_errors'] = result['upstream_errors']
      matrix[key]['setup_status'] = 'SUCCESS'

      if result['status'] == 'SUCCESS':
        matrix[key]['successful_apis'].add(
          f"{result['api_key']}({result['api_key_int']})")
      elif result['status'] == 'ERROR':
        matrix[key]['failed_apis'].add(
          f"{result['api_key']}({result['api_key_int']})")

    return matrix

  def _generate_detailed_csv(self, output_dir):
    """Generate detailed CSV report"""
    csv_file = os.path.join(output_dir, "detailed_api_usage.csv")
    with open(csv_file, 'w', newline='') as f:
      fieldnames = ['api_key', 'api_key_int', 'api_version', 'client_version',
                    'server_version',
                    'request_count', 'client_errors', 'upstream_errors',
                    'status', 'test_name', 'timestamp', 'failure_type', 'status_message']
      writer = csv.DictWriter(f, fieldnames=fieldnames)
      writer.writeheader()
      
      # Add failure_type and status_message fields to results that don't have them
      for result in self.results:
        if 'failure_type' not in result:
          result['failure_type'] = None
        if 'status_message' not in result:
          result['status_message'] = None
      
      writer.writerows(self.results)
    return csv_file

  def _generate_summary_table(self, output_dir, matrix):
    """Generate summary table report"""
    summary_file = os.path.join(output_dir, "compatibility_summary.txt")
    with open(summary_file, 'w') as f:
      f.write("KAFKA CLIENT COMPATIBILITY TEST RESULTS\n")
      f.write("=" * 120 + "\n\n")
      f.write(
        f"{'CLIENT':<8} | {'SERVER':<8} | {'SUCCESSFUL_APIS':<25} | {'FAILED_APIS':<15} | {'REQUESTS':<8} | {'ERRORS':<8} | {'STATUS':<15} | FAILURE_REASON\n")
      f.write("-" * 120 + "\n")

      for key, data in sorted(matrix.items()):
        client_ver, server_ver = key.split('-')
        
        # Check if this was a setup failure
        if data['setup_status'] == 'SETUP_FAILED':
          status = "🚫 SETUP_FAILED"
          failure_reason = data.get('failure_type', 'UNKNOWN')
          successful_apis = "N/A"
          failed_apis = "N/A"
          requests = 0
          total_errors = 0
        else:
          successful_apis = ','.join(sorted(data['successful_apis']))[
                            :20] + "..." if len(
            ','.join(data['successful_apis'])) > 20 else ','.join(
            sorted(data['successful_apis']))
          failed_apis = ','.join(sorted(data['failed_apis']))[:10] + "..." if len(
            ','.join(data['failed_apis'])) > 10 else ','.join(
            sorted(data['failed_apis']))

          total_errors = data['total_client_errors'] + data[
            'total_upstream_errors']
          requests = int(data['total_requests'])
          failure_reason = ""

          if total_errors == 0 and requests > 0:
            status = "✅ PASS"
          elif total_errors > 0:
            status = "❌ FAIL"
          else:
            status = "⚠️ NO_DATA"

        f.write(
          f"{client_ver:<8} | {server_ver:<8} | {successful_apis:<25} | {failed_apis:<15} | {requests:<8} | {int(total_errors):<8} | {status:<15} | {failure_reason}\n")
    return summary_file

  def _generate_api_reference(self, output_dir):
    """Generate API key reference file"""
    api_ref_file = os.path.join(output_dir, "api_key_reference.txt")
    with open(api_ref_file, 'w') as f:
      f.write("KAFKA API KEY REFERENCE\n")
      f.write("=" * 50 + "\n")
      f.write(f"{'API_NAME':<30} | {'API_INT':<8}\n")
      f.write("-" * 50 + "\n")

      # Show only APIs that were actually used
      used_apis = set()
      for result in self.results:
        used_apis.add((result['api_key'], result['api_key_int']))

      for api_name, api_int in sorted(used_apis,
                                      key=lambda x: x[1] if isinstance(x[1],
                                                                       int) else 999):
        f.write(f"{api_name:<30} | {api_int:<8}\n")
    return api_ref_file

  def _generate_json_report(self, output_dir, matrix):
    """Generate JSON report"""
    json_file = os.path.join(output_dir, "compatibility_report.json")
    
    # Count setup failures and successes
    setup_failures = sum(1 for v in matrix.values() if v['setup_status'] == 'SETUP_FAILED')
    setup_successes = sum(1 for v in matrix.values() if v['setup_status'] == 'SUCCESS')
    
    with open(json_file, 'w') as f:
      json.dump({
        'test_timestamp': datetime.now().isoformat(),
        'total_combinations': len(matrix),
        'setup_successes': setup_successes,
        'setup_failures': setup_failures,
        'total_api_calls': len([r for r in self.results if r['status'] != 'SETUP_FAILED']),
        'matrix_results': {
          k: {**v, 'apis': list(v['apis']), 'api_ints': list(v['api_ints']),
              'api_versions': list(v['api_versions']),
              'successful_apis': list(v['successful_apis']),
              'failed_apis': list(v['failed_apis'])} for k, v in
          matrix.items()},
        'api_key_mapping': KAFKA_API_KEYS,
        'setup_failed_combinations': [k for k, v in matrix.items() if v['setup_status'] == 'SETUP_FAILED']
      }, f, indent=2, default=str)
    return json_file

  def generate_report(self, output_dir):
    """Generate comprehensive compatibility report"""
    print(f"\nGenerating reports in: {output_dir}")

    if not self.results:
      print("No results to process!")
      return

    # Build matrix data from results
    matrix = self._build_matrix_data()

    # Generate all report files
    csv_file = self._generate_detailed_csv(output_dir)
    summary_file = self._generate_summary_table(output_dir, matrix)
    api_ref_file = self._generate_api_reference(output_dir)
    json_file = self._generate_json_report(output_dir, matrix)

    print(f"\nReports generated:")
    print(f"  📊 Summary: {summary_file}")
    print(f"  📋 Detailed CSV: {csv_file}")
    print(f"  📖 API Reference: {api_ref_file}")
    print(f"  🗃️  JSON Report: {json_file}")


if __name__ == "__main__":
  if len(sys.argv) < 2:
    print("Usage:")
    print("  python3 enhanced_metrics_parser.py <results_directory>")
    print(
      "  python3 enhanced_metrics_parser.py /path/to/compatibility-results/20231103_140230")
    sys.exit(1)

  results_dir = sys.argv[1]

  if not os.path.exists(results_dir):
    print(f"Error: Directory {results_dir} does not exist")
    sys.exit(1)

  parser = EnhancedKroxyliciousMetricsParser()
  parser.process_results_directory(results_dir)
  parser.generate_report(results_dir)
