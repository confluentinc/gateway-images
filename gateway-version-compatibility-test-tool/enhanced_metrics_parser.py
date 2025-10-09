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
    # Using bytes_sum for more accurate balance checking
    patterns = {
        'client_to_proxy_request_bytes': r'kroxylicious_client_to_proxy_request_size_bytes_sum\{api_key="([^"]*)",api_version="([^"]*)",decoded="[^"]*",node_id="([^"]*)",virtual_cluster="([^"]*)"\} ([0-9.]+)',
        'proxy_to_server_request_bytes': r'kroxylicious_proxy_to_server_request_size_bytes_sum\{api_key="([^"]*)",api_version="([^"]*)",decoded="[^"]*",node_id="([^"]*)",virtual_cluster="([^"]*)"\} ([0-9.]+)',
        'server_to_proxy_response_bytes': r'kroxylicious_server_to_proxy_response_size_bytes_sum\{api_key="([^"]*)",api_version="([^"]*)",decoded="[^"]*",node_id="([^"]*)",virtual_cluster="([^"]*)"\} ([0-9.]+)',
        'proxy_to_client_response_bytes': r'kroxylicious_proxy_to_client_response_size_bytes_sum\{api_key="([^"]*)",api_version="([^"]*)",decoded="[^"]*",node_id="([^"]*)",virtual_cluster="([^"]*)"\} ([0-9.]+)'
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
                    'client_to_proxy_request_bytes': 0,
                    'proxy_to_server_request_bytes': 0,
                    'server_to_proxy_response_bytes': 0,
                    'proxy_to_client_response_bytes': 0
                }
            metrics[key][metric_type] += float(count)
    
    # Process each API+virtual_cluster combination
    for key, data in metrics.items():
        api_key_int = get_api_key_int(data['api_key'])
        
        # Calculate totals using bytes
        # Balance check: 
        # 1. client_to_proxy_request_bytes = proxy_to_server_request_bytes (proxy forwards all client requests)
        # 2. server_to_proxy_response_bytes = proxy_to_client_response_bytes (proxy forwards all server responses)
        client_to_proxy_bytes = data['client_to_proxy_request_bytes']
        proxy_to_server_bytes = data['proxy_to_server_request_bytes']
        server_to_proxy_bytes = data['server_to_proxy_response_bytes']
        proxy_to_client_bytes = data['proxy_to_client_response_bytes']
        
        # Check both balance conditions
        request_balance = (client_to_proxy_bytes == proxy_to_server_bytes)
        response_balance = (server_to_proxy_bytes == proxy_to_client_bytes)
        
        if request_balance and response_balance and client_to_proxy_bytes > 0:
            status = 'SUCCESS'
            client_errors = 0
            upstream_errors = 0
        elif client_to_proxy_bytes > 0:
            status = 'ERROR'  # Imbalanced - proxy didn't forward all bytes correctly
            # Calculate failed bytes (use the larger imbalance)
            request_failed = abs(client_to_proxy_bytes - proxy_to_server_bytes)
            response_failed = abs(server_to_proxy_bytes - proxy_to_client_bytes)
            client_errors = max(request_failed, response_failed)
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
            'request_bytes': client_to_proxy_bytes,
            'response_bytes': proxy_to_client_bytes,
            'client_errors': client_errors,
            'upstream_errors': upstream_errors,
            'status': status,
            'client_version': client_version,
            'server_version': server_version,
            'test_name': test_name,
            'timestamp': datetime.now().isoformat(),
            # Detailed breakdown for debugging
            'client_to_proxy_request_bytes': data['client_to_proxy_request_bytes'],
            'proxy_to_server_request_bytes': data['proxy_to_server_request_bytes'],
            'server_to_proxy_response_bytes': data['server_to_proxy_response_bytes'],
            'proxy_to_client_response_bytes': data['proxy_to_client_response_bytes']
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
      'total_request_bytes': 0,
      'total_response_bytes': 0,
      'total_client_errors': 0,
      'total_upstream_errors': 0,
      'successful_apis': set(),
      'failed_apis': set(),
      'virtual_cluster_breakdown': defaultdict(lambda: {
        'total_request_bytes': 0,
        'total_response_bytes': 0,
        'total_errors': 0,
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
      matrix[key]['total_request_bytes'] += result['request_bytes']
      matrix[key]['total_response_bytes'] += result['response_bytes']
      matrix[key]['total_client_errors'] += result['client_errors']
      matrix[key]['total_upstream_errors'] += result['upstream_errors']

      # Update virtual cluster breakdown
      matrix[key]['virtual_cluster_breakdown'][vc_key]['total_request_bytes'] += result['request_bytes']
      matrix[key]['virtual_cluster_breakdown'][vc_key]['total_response_bytes'] += result['response_bytes']
      matrix[key]['virtual_cluster_breakdown'][vc_key]['total_errors'] += result['client_errors']

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
                    'client_version', 'server_version', 'request_bytes', 'response_bytes',
                    'client_errors', 'upstream_errors', 'status', 'test_name', 'timestamp',
                    'client_to_proxy_request_bytes', 'proxy_to_server_request_bytes',
                    'server_to_proxy_response_bytes', 'proxy_to_client_response_bytes']
      writer = csv.DictWriter(f, fieldnames=fieldnames)
      writer.writeheader()
      writer.writerows(self.results)
    return csv_file

  def _generate_summary_report(self, output_dir, matrix, junit_results=None):
    """Generate summary report"""
    summary_file = os.path.join(output_dir, "compatibility_summary.txt")
    with open(summary_file, 'w') as f:
      f.write("KAFKA CLIENT-SERVER COMPATIBILITY MATRIX\n")
      f.write("=" * 60 + "\n\n")
      
      # Generate summary matrix at the top
      f.write("SUMMARY MATRIX - ALL TESTED COMBINATIONS\n")
      f.write("-" * 80 + "\n")
      
      # Create table header
      f.write(f"{'Client':<10} {'Server':<10} {'Auth_Mode':<12} {'Status':<8} {'Tests_Run':<10} {'Tests_Passed':<12} {'Tests_Failed':<12}\n")
      f.write("-" * 88 + "\n")
      
      # Process each combination and create rows for each authentication mode
      for key, data in sorted(matrix.items()):
        client_ver, server_ver = key.split('-')
        
        # Get JUnit results for this combination
        if junit_results and key in junit_results:
          vc_results = junit_results[key]
          
          # Create a row for each virtual cluster (authentication mode)
          for vc_name, vc_data in data['virtual_cluster_breakdown'].items():
            # Determine virtual cluster type
            if 'sasl' in vc_name:
              auth_mode = "SASL"
            elif 'ssl' in vc_name:
              auth_mode = "SSL"
            else:
              auth_mode = "PLAINTEXT"
            
            # Get JUnit test results for this virtual cluster
            if auth_mode in vc_results:
              junit_data = vc_results[auth_mode]
              tests_run = junit_data['tests_run']
              tests_failed = junit_data['failures'] + junit_data['errors']
              tests_passed = tests_run - tests_failed
              
              # Determine status based on test results
              if tests_failed == 0:
                status = "✅"
              else:
                status = "❌"
            else:
              tests_run = 0
              tests_passed = 0
              tests_failed = 0
              status = "❓"
            
            f.write(f"{client_ver:<10} {server_ver:<10} {auth_mode:<12} {status:<8} {tests_run:<10} {tests_passed:<12} {tests_failed:<12}\n")
        else:
          # No JUnit results available, show N/A
          f.write(f"{client_ver:<10} {server_ver:<10} {'N/A':<12} {'❓':<8} {'N/A':<10} {'N/A':<12} {'N/A':<12}\n")
      
      f.write("\n")
      f.write("DETAILED BREAKDOWN BY COMBINATION\n")
      f.write("=" * 50 + "\n\n")
      
      for key, data in sorted(matrix.items()):
        client_ver, server_ver = key.split('-')
        f.write(f"CLIENT: {client_ver} | SERVER: {server_ver}\n")
        f.write("-" * 40 + "\n")
        
        # Overall summary
        total_errors = data['total_client_errors'] + data['total_upstream_errors']
        
        # Check if only acceptable APIs are failing
        acceptable_failures = {'METADATA', 'DESCRIBE_CLUSTER', 'FIND_COORDINATOR', 'API_VERSIONS'}
        failed_apis = {api.split('(')[0] for api in data['failed_apis']}  # Extract API name without version
        unacceptable_failures = failed_apis - acceptable_failures
        
        if data['total_request_bytes'] > 0 and total_errors == 0:
          overall_status = "✅ PASS"
        elif data['total_request_bytes'] > 0 and len(unacceptable_failures) == 0:
          overall_status = "✅ PASS (with acceptable api failures)"
        elif data['total_request_bytes'] > 0 and total_errors > 0:
          overall_status = "❌ FAIL"
        else:
          overall_status = "⚠️ NO_DATA"
        
        f.write(f"OVERALL STATUS: {overall_status}\n")
        f.write(f"Total Request Bytes: {int(data['total_request_bytes'])} | Total Response Bytes: {int(data['total_response_bytes'])} | Error Bytes: {int(total_errors)}\n")
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
          
          vc_errors = vc_data['total_errors']
          
          # Check if only acceptable APIs are failing for this virtual cluster
          acceptable_failures = {'METADATA', 'DESCRIBE_CLUSTER', 'FIND_COORDINATOR', 'API_VERSIONS'}
          vc_failed_apis = {api.split('(')[0] for api in vc_data['failed_apis']}  # Extract API name without version
          vc_unacceptable_failures = vc_failed_apis - acceptable_failures
          
          if vc_data['total_request_bytes'] > 0 and vc_errors == 0:
            vc_status = "✅ PASS"
          elif vc_data['total_request_bytes'] > 0 and len(vc_unacceptable_failures) == 0:
            vc_status = "✅ PASS (with acceptable api failures)"
          elif vc_data['total_request_bytes'] > 0 and vc_errors > 0:
            vc_status = "❌ FAIL"
          else:
            vc_status = "⚠️ NO_DATA"
          
          # Get JUnit test results for this virtual cluster
          junit_info = ""
          if junit_results and key in junit_results and vc_type in junit_results[key]:
            junit_data = junit_results[key][vc_type]
            junit_info = f" | Tests: {junit_data['tests_run']} | Failures: {junit_data['failures']} | Errors: {junit_data['errors']} | Skipped: {junit_data['skipped']}"
          
          f.write(f"  {vc_type:<12} | {vc_status} | Request Bytes: {int(vc_data['total_request_bytes']):<8} | Response Bytes: {int(vc_data['total_response_bytes']):<8} | Error Bytes: {int(vc_errors):<6} | Success: {len(vc_data['successful_apis']):<3} | Failed: {len(vc_data['failed_apis'])}{junit_info}\n")
        
        f.write("\n")
        
        # Detailed API breakdown
        if data['failed_apis']:
          # Separate acceptable and unacceptable failed APIs
          acceptable_failures = {'METADATA', 'DESCRIBE_CLUSTER', 'FIND_COORDINATOR', 'API_VERSIONS'}
          acceptable_failed_apis = []
          unacceptable_failed_apis = []
          
          for api in data['failed_apis']:
            api_name = api.split('(')[0]  # Extract API name without version
            if api_name in acceptable_failures:
              acceptable_failed_apis.append(api)
            else:
              unacceptable_failed_apis.append(api)
          
          # Show acceptable failed APIs with warning symbol
          if acceptable_failed_apis:
            f.write("ACCEPTABLE FAILED APIs:\n")
            for api in sorted(acceptable_failed_apis):
              f.write(f"  ⚠️ {api}\n")
            f.write("\n")
          
          # Show unacceptable failed APIs with error symbol
          if unacceptable_failed_apis:
            f.write("FAILED APIs:\n")
            for api in sorted(unacceptable_failed_apis):
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

  def generate_reports(self, output_dir, junit_results=None):
    """Generate all reports"""
    os.makedirs(output_dir, exist_ok=True)

    # Generate compatibility matrix
    matrix = self.generate_compatibility_matrix()

    # Generate detailed CSV
    csv_file = self._generate_detailed_csv(output_dir)
    print(f"Generated detailed CSV: {csv_file}")

    # Generate summary report
    summary_file = self._generate_summary_report(output_dir, matrix, junit_results)
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
    
    # Calculate overall compatibility percentage (including acceptable failures)
    def is_test_passing(data):
      if data['total_request_bytes'] == 0:
        return False
      if (data['total_client_errors'] + data['total_upstream_errors']) == 0:
        return True
      # Check if only acceptable APIs are failing
      acceptable_failures = {'METADATA', 'DESCRIBE_CLUSTER', 'FIND_COORDINATOR', 'API_VERSIONS'}
      failed_apis = {api.split('(')[0] for api in data['failed_apis']}
      unacceptable_failures = failed_apis - acceptable_failures
      return len(unacceptable_failures) == 0
    
    passed_tests = sum(1 for data in matrix.values() if is_test_passing(data))
    total_tests = len([data for data in matrix.values() if data['total_request_bytes'] > 0])
    compatibility_percentage = (passed_tests / total_tests * 100) if total_tests > 0 else 0
    
    # Calculate test summary (including acceptable failures)
    passed_tests_count = sum(1 for data in matrix.values() if is_test_passing(data))
    failed_tests_count = sum(1 for data in matrix.values() 
                           if data['total_request_bytes'] > 0 and not is_test_passing(data))
    no_data_tests = sum(1 for data in matrix.values() if data['total_request_bytes'] == 0)
    total_api_bytes = sum(data['total_request_bytes'] for data in matrix.values())
    
    # Convert matrix data for JSON serialization
    enhanced_matrix = {}
    for k, v in matrix.items():
      client_ver, server_ver = k.split('-')
      
      # Determine status (including acceptable failures)
      total_errors = v['total_client_errors'] + v['total_upstream_errors']
      acceptable_failures = {'METADATA', 'DESCRIBE_CLUSTER', 'FIND_COORDINATOR', 'API_VERSIONS'}
      failed_apis = {api.split('(')[0] for api in v['failed_apis']}
      unacceptable_failures = failed_apis - acceptable_failures
      
      if v['total_request_bytes'] > 0 and total_errors == 0:
        status = "PASS"
        status_emoji = "✅"
      elif v['total_request_bytes'] > 0 and len(unacceptable_failures) == 0:
        status = "PASS_ACCEPTABLE"
        status_emoji = "✅"
      elif v['total_request_bytes'] > 0 and total_errors > 0:
        status = "FAIL"
        status_emoji = "❌"
      else:
        status = "NO_DATA"
        status_emoji = "⚠️"
      
      # Convert virtual cluster breakdown to serializable format
      vc_breakdown = {}
      for vc_name, vc_data in v['virtual_cluster_breakdown'].items():
        vc_breakdown[vc_name] = {
          'total_request_bytes': vc_data['total_request_bytes'],
          'total_response_bytes': vc_data['total_response_bytes'],
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
        'compatibility_score': 100 if status in ["PASS", "PASS_ACCEPTABLE"] else (50 if status == "NO_DATA" else 0)
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
        'total_api_bytes': int(total_api_bytes)
      },
      'matrix_results': enhanced_matrix,
      'api_key_mapping': KAFKA_API_KEYS
    }
    
    with open(json_file, 'w') as f:
      json.dump(report_data, f, indent=2)
    
    return json_file

  def parse_junit_results(self, results_dir):
    """Parse JUnit test results from TXT files"""
    junit_results = {}
    
    print(f"🔍 Scanning directory: {results_dir}")
    print(f"📁 Directory contents: {os.listdir(results_dir)}")
    
    # Look for JUnit result directories
    for item in os.listdir(results_dir):
      if item.endswith('_junit'):
        print(f"✅ Found JUnit directory: {item}")
        # Extract client and server versions from directory name
        match = re.match(r'java([^_]+)_server([^_]+)_junit', item)
        if match:
          client_version = match.group(1)
          server_version = match.group(2)
          key = f"{client_version}-{server_version}"
          
          junit_results[key] = {}
          
          # Parse each virtual cluster's test results
          junit_dir = os.path.join(results_dir, item)
          print(f"📂 JUnit directory contents: {os.listdir(junit_dir)}")
          for vc_dir in os.listdir(junit_dir):
            vc_path = os.path.join(junit_dir, vc_dir)
            if os.path.isdir(vc_path):
              print(f"🔍 Virtual cluster: {vc_dir}")
              # Look for TXT test result files
              for file in os.listdir(vc_path):
                if file.endswith('.txt'):
                  print(f"📄 Found TXT file: {file}")
                  txt_file = os.path.join(vc_path, file)
                  try:
                    with open(txt_file, 'r') as f:
                      content = f.read()
                    
                    # Parse the test results line
                    # Format: "Tests run: 14, Failures: 0, Errors: 0, Skipped: 0, Time elapsed: 36.43 s"
                    print(f"📝 TXT file content: {content[:200]}...")
                    match = re.search(r'Tests run: (\d+), Failures: (\d+), Errors: (\d+), Skipped: (\d+)', content)
                    if match:
                      tests_run = int(match.group(1))
                      failures = int(match.group(2))
                      errors = int(match.group(3))
                      skipped = int(match.group(4))
                      print(f"✅ Parsed: Tests={tests_run}, Failures={failures}, Errors={errors}, Skipped={skipped}")
                    else:
                      print(f"❌ Could not parse test results from content")
                      continue
                      
                    # Map virtual cluster directory names to our standard names
                    if 'sasl' in vc_dir:
                      vc_name = 'SASL'
                    elif 'ssl' in vc_dir:
                      vc_name = 'SSL'
                    else:
                      vc_name = 'PLAINTEXT'
                    
                    junit_results[key][vc_name] = {
                      'tests_run': tests_run,
                      'failures': failures,
                      'errors': errors,
                      'skipped': skipped
                    }
                    
                  except Exception as e:
                    print(f"Warning: Error processing JUnit TXT file {txt_file}: {e}")
    
    return junit_results


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

  # Parse JUnit test results
  print("Parsing JUnit test results...")
  junit_results = parser.parse_junit_results(results_dir)
  print(f"Found JUnit results for {len(junit_results)} test combinations")

  # Generate reports
  output_dir = os.path.join(results_dir, "reports")
  reports = parser.generate_reports(output_dir, junit_results)

  print(f"\nReports generated in: {output_dir}")
  for report_type, report_path in reports.items():
    print(f"  {report_type}: {report_path}")


if __name__ == "__main__":
  main()