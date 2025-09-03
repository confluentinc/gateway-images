#!/usr/bin/env python3
"""
Kroxylicious Compatibility Test Metrics Parser
Parses Prometheus metrics to generate compatibility reports
"""

import re
import requests
import csv
import json
import time
from collections import defaultdict
from datetime import datetime

class KroxyliciousMetricsParser:
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

  def parse_api_usage(self, metrics_text, client_version, server_version, test_name):
    """Extract API usage data from metrics"""
    api_data = {}

    # Parse client-to-proxy requests
    request_pattern = r'kroxylicious_client_to_proxy_request_total\{.*api_key="([^"]*)".*api_version="([^"]*)".*\} ([0-9.]+)'
    requests_matches = re.findall(request_pattern, metrics_text)

    for api_key, api_version, count in requests_matches:
      key = f"{api_key}_{api_version}"
      api_data[key] = {
        'api_key': api_key,
        'api_version': api_version,
        'request_count': float(count),
        'client_version': client_version,
        'server_version': server_version,
        'test_name': test_name
      }

    # Parse error counts
    error_pattern = r'kroxylicious_client_to_proxy_errors_total\{.*\} ([0-9.]+)'
    error_matches = re.findall(error_pattern, metrics_text)
    total_errors = sum(float(e) for e in error_matches)

    # Parse upstream connection failures
    upstream_error_pattern = r'kroxylicious_upstream_connection_failures_total\{.*\} ([0-9.]+)'
    upstream_matches = re.findall(upstream_error_pattern, metrics_text)
    upstream_errors = sum(float(e) for e in upstream_matches)

    # Add error info to each API
    for key in api_data:
      api_data[key]['total_errors'] = total_errors
      api_data[key]['upstream_errors'] = upstream_errors

    return api_data

  def run_single_test(self, client_version, server_version):
    """Run a single compatibility test combination"""
    test_name = f"java-{client_version}_server-{server_version}"
    print(f"Testing: Java Client {client_version} → Server {server_version}")

    # Wait for test to complete (called by external script)
    time.sleep(2)

    # Scrape metrics
    metrics_text = self.scrape_metrics()
    if not metrics_text:
      return None

    # Parse API usage
    api_data = self.parse_api_usage(metrics_text, client_version, server_version, test_name)

    # Store results
    self.results.extend(api_data.values())

    return api_data

  def generate_compatibility_matrix(self):
    """Generate compatibility matrix from all test results"""

    # Group by client-server combination
    matrix = defaultdict(lambda: {
      'apis': set(),
      'api_versions': set(),
      'total_requests': 0,
      'total_errors': 0,
      'upstream_errors': 0
    })

    for result in self.results:
      key = f"{result['client_version']}-{result['server_version']}"
      matrix[key]['apis'].add(result['api_key'])
      matrix[key]['api_versions'].add(result['api_version'])
      matrix[key]['total_requests'] += result['request_count']
      matrix[key]['total_errors'] += result['total_errors']
      matrix[key]['upstream_errors'] += result['upstream_errors']

    return matrix

  def generate_report(self, output_dir):
    """Generate comprehensive compatibility report"""

    # 1. Raw CSV data
    csv_file = f"{output_dir}/detailed_api_usage.csv"
    with open(csv_file, 'w', newline='') as f:
      if self.results:
        writer = csv.DictWriter(f, fieldnames=self.results[0].keys())
        writer.writeheader()
        writer.writerows(self.results)

    # 2. Compatibility matrix
    matrix = self.generate_compatibility_matrix()

    # 3. Summary table (your requested format)
    summary_file = f"{output_dir}/compatibility_summary.txt"
    with open(summary_file, 'w') as f:
      f.write("KAFKA CLIENT COMPATIBILITY TEST RESULTS\n")
      f.write("="*80 + "\n\n")
      f.write(f"{'CLIENT_VER':<12} | {'SERVER_VER':<12} | {'TESTED_APIS':<25} | {'API_VERSIONS':<15} | {'ERRORS':<8} | STATUS\n")
      f.write("-" * 80 + "\n")

      for key, data in sorted(matrix.items()):
        client_ver, server_ver = key.split('-')
        apis = ','.join(sorted(data['apis']))[:20] + "..." if len(','.join(data['apis'])) > 20 else ','.join(sorted(data['apis']))
        versions = ','.join(sorted(data['api_versions']))
        errors = int(data['total_errors'])
        requests = int(data['total_requests'])

        if errors == 0 and requests > 0:
          status = "✅ PASS"
        elif errors > 0:
          status = "❌ FAIL"
        else:
          status = "⚠️ NO_DATA"

        f.write(f"{client_ver:<12} | {server_ver:<12} | {apis:<25} | {versions:<15} | {errors:<8} | {status}\n")

    # 4. JSON report for programmatic use
    json_file = f"{output_dir}/compatibility_report.json"
    with open(json_file, 'w') as f:
      json.dump({
        'test_timestamp': datetime.now().isoformat(),
        'total_combinations': len(matrix),
        'results': dict(matrix),
        'raw_data': self.results
      }, f, indent=2, default=str)

    print(f"\nReports generated:")
    print(f"  Summary: {summary_file}")
    print(f"  Detailed CSV: {csv_file}")
    print(f"  JSON Report: {json_file}")

# Usage example
if __name__ == "__main__":
  import sys
  import os

  if len(sys.argv) < 2:
    print("Usage: python3 metrics_parser.py <output_dir> [client_version] [server_version]")
    sys.exit(1)

  output_dir = sys.argv[1]
  os.makedirs(output_dir, exist_ok=True)

  parser = KroxyliciousMetricsParser()

  if len(sys.argv) == 4:
    # Single test
    client_version = sys.argv[2]
    server_version = sys.argv[3]
    parser.run_single_test(client_version, server_version)

  # Generate reports
  parser.generate_report(output_dir)