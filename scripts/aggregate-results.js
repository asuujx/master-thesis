#!/usr/bin/env node
'use strict';

// Aggregates all run data across clouds into two CSVs:
//   results/summary.csv  — one row per (cloud × testName), aggregated stats from summary.json
//   results/raw.csv      — one row per (cloud × iteration × testName), raw measurements
//
// Usage: node scripts/aggregate-results.js
//   Reads from: metrics/{aws,azure,gcp}/*/
//   Writes to:  metrics/results/

const fs   = require('fs');
const path = require('path');

const METRICS_DIR = path.resolve(__dirname, '../metrics');
const OUT_DIR     = path.resolve(__dirname, '../metrics/results');
const CLOUDS      = ['aws', 'azure', 'gcp'];

const NUMERIC_METRICS = [
  'testDuration',
  'ttfb', 'domInteractive', 'domContentLoaded', 'loadComplete',
  'redirectTime', 'dnsLookup', 'tcpConnect', 'tlsHandshake',
  'serverProcessing', 'contentDownload',
  'transferSize', 'encodedBodySize', 'decodedBodySize',
  'resourceCount', 'totalResourceTransferSize',
  'fcp', 'lcp', 'cls', 'tbt', 'inp',
  'jsHeapUsed', 'jsHeapTotal',
];

const STAT_KEYS = ['mean', 'stddev', 'min', 'p50', 'p95', 'max', 'n'];

const SKIP_ITER_FILES = new Set([
  'provider_timings.json', 'runner_timings.json', 'network_rtt.json',
  'kube_metrics_before.json', 'kube_metrics_after.json',
]);

function readJson(p) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); }
  catch { return null; }
}

function csvEscape(val) {
  if (val === null || val === undefined) return '';
  const s = String(val);
  return (s.includes(',') || s.includes('"') || s.includes('\n'))
    ? '"' + s.replace(/"/g, '""') + '"'
    : s;
}

function csvRow(values) { return values.map(csvEscape).join(','); }

// ── Discover run directories sorted by date ────────────────────────────────────
function findRunDirs() {
  const runs = [];
  for (const cloud of CLOUDS) {
    const cloudDir = path.join(METRICS_DIR, cloud);
    if (!fs.existsSync(cloudDir)) continue;
    for (const entry of fs.readdirSync(cloudDir).sort()) {
      const runDir = path.join(cloudDir, entry);
      if (fs.statSync(runDir).isDirectory()) {
        runs.push({ cloud, runDir, runId: entry });
      }
    }
  }
  return runs;
}

// ── Summary CSV ────────────────────────────────────────────────────────────────
function buildSummaryCSV(runs) {
  const headers = [
    'cloud', 'environment', 'nodeType', 'nodeCount', 'region', 'runnerType',
    'runDate', 'iterationCount',
    'testName', 'passCount', 'flakyCount', 'flakyRate',
    ...NUMERIC_METRICS.flatMap(m => STAT_KEYS.map(s => `${m}_${s}`)),
    'costComputeUsd', 'costControlPlaneUsd', 'costLoadBalancerUsd', 'costCiRunnerUsd', 'costTotalUsd',
  ];

  const rows = [headers];

  for (const { runDir, runId } of runs) {
    const summary  = readJson(path.join(runDir, 'summary.json'));
    const metadata = readJson(path.join(runDir, 'run_metadata.json'));
    const costs    = readJson(path.join(runDir, 'cost_estimate.json'));
    if (!summary || !metadata) continue;

    const runDate  = runId.slice(0, 10); // "2026-05-09"
    const costCols = costs
      ? [costs.costs.computeUsd, costs.costs.controlPlaneUsd,
         costs.costs.loadBalancerUsd, costs.costs.ciRunnerUsd, costs.costs.totalUsd]
      : ['', '', '', '', ''];

    for (const test of summary.tests) {
      const metricCols = NUMERIC_METRICS.flatMap(m => {
        const s = test.metrics[m];
        return STAT_KEYS.map(k => (s ? s[k] : ''));
      });

      rows.push([
        summary.cloud, summary.environment,
        metadata.nodeType, metadata.nodeCount,
        metadata.clusterRegion, metadata.runnerType,
        runDate, summary.iterationCount,
        test.testName, test.passCount, test.flakyCount, test.flakyRate,
        ...metricCols,
        ...costCols,
      ]);
    }
  }

  return rows.map(csvRow).join('\n') + '\n';
}

// ── Raw (per-iteration) CSV ────────────────────────────────────────────────────
function buildRawCSV(runs) {
  const headers = [
    'cloud', 'environment', 'nodeType', 'nodeCount', 'region', 'runnerType',
    'runDate', 'iteration', 'timestamp',
    'testName', 'passed', 'attemptNumber',
    ...NUMERIC_METRICS,
    'runnerExecutionSeconds', 'runnerQueueSeconds',
    'installSeconds', 'testSeconds',
    'rttDnsSecondsMean', 'rttTcpSecondsMean', 'rttTtfbSecondsMean',
  ];

  const rows = [headers];

  for (const { runDir, runId } of runs) {
    const metadata = readJson(path.join(runDir, 'run_metadata.json'));
    if (!metadata) continue;

    const runDate = runId.slice(0, 10);

    // Numeric sort: lexicographic order would put iteration-10 before iteration-2.
    const iterDirs = fs.readdirSync(runDir)
      .filter(d => /^iteration-\d+$/.test(d))
      .sort((a, b) => parseInt(a.split('-')[1]) - parseInt(b.split('-')[1]));

    for (const iterDir of iterDirs) {
      const iterNum  = parseInt(iterDir.split('-')[1]);
      const iterPath = path.join(runDir, iterDir);

      const timings        = readJson(path.join(iterPath, 'provider_timings.json')) ?? {};
      const runnerTimings  = readJson(path.join(iterPath, 'runner_timings.json'))  ?? {};
      const rttData        = readJson(path.join(iterPath, 'network_rtt.json'))      ?? [];

      // Probes that failed to measure a metric omit the key entirely, so filter
      // for numbers before averaging. toFixed(6) keeps sub-millisecond precision.
      const rttMean = (key) => {
        const vals = rttData.filter(p => typeof p[key] === 'number').map(p => p[key]);
        return vals.length
          ? (vals.reduce((a, b) => a + b, 0) / vals.length).toFixed(6)
          : '';
      };

      // artifacts-*.json files hold Playwright attachment metadata, not test result records.
      const testFiles = fs.readdirSync(iterPath)
        .filter(f => f.endsWith('.json') && !f.startsWith('artifacts-') && !SKIP_ITER_FILES.has(f));

      const allRecords = [];
      for (const file of testFiles) {
        try {
          const parsed = JSON.parse(fs.readFileSync(path.join(iterPath, file), 'utf8'));
          const records = Array.isArray(parsed) ? parsed : [parsed];
          allRecords.push(...records.filter(r => r.testName));
        } catch { /* skip unreadable files */ }
      }

      // Keep only the final attempt per test (same logic as summarize.js)
      const finalByTest = {};
      for (const rec of allRecords) {
        const prev = finalByTest[rec.testName];
        if (!prev || (rec.attemptNumber ?? 1) > (prev.attemptNumber ?? 1)) {
          finalByTest[rec.testName] = rec;
        }
      }

      for (const rec of Object.values(finalByTest)) {
        rows.push([
          metadata.cloud, metadata.environment,
          metadata.nodeType, metadata.nodeCount,
          metadata.clusterRegion, metadata.runnerType,
          runDate, iterNum, rec.timestamp ?? '',
          rec.testName, rec.passed, rec.attemptNumber ?? 1,
          ...NUMERIC_METRICS.map(f => rec[f] ?? ''),
          timings.runnerExecutionSeconds ?? '',
          timings.runnerQueueSeconds ?? '',
          runnerTimings.installSeconds ?? '',
          runnerTimings.testSeconds ?? '',
          rttMean('dnsSeconds'),
          rttMean('tcpSeconds'),
          rttMean('ttfbSeconds'),
        ]);
      }
    }
  }

  return rows.map(csvRow).join('\n') + '\n';
}

// ── Runs (per-run economics) CSV ───────────────────────────────────────────────
function buildRunsCSV(runs) {
  const headers = [
    'cloud', 'environment', 'nodeType', 'nodeCount', 'region', 'runnerType',
    'runDate', 'iterationCount',
    'infrastructureProvisioningSeconds', 'appDeploySeconds',
    'lbReadySeconds', 'totalTestSuiteDurationSeconds',
    'totalRunnerBilledMinutes', 'totalRunnerExecSeconds',
    'costComputeUsd', 'costControlPlaneUsd', 'costLoadBalancerUsd', 'costCiRunnerUsd', 'costTotalUsd',
  ];

  const rows = [headers];

  for (const { runDir, runId } of runs) {
    const metadata = readJson(path.join(runDir, 'run_metadata.json'));
    const costs    = readJson(path.join(runDir, 'cost_estimate.json'));
    if (!metadata) continue;

    const runDate  = runId.slice(0, 10);
    // Runner timing lives at the top level of cost_estimate.json;
    // dollar amounts are nested under costs.costs.
    const costCols = costs
      ? [costs.totalRunnerBilledMinutes, costs.totalRunnerExecSeconds,
         costs.costs.computeUsd, costs.costs.controlPlaneUsd,
         costs.costs.loadBalancerUsd, costs.costs.ciRunnerUsd, costs.costs.totalUsd]
      : ['', '', '', '', '', '', ''];

    rows.push([
      metadata.cloud, metadata.environment,
      metadata.nodeType, metadata.nodeCount,
      metadata.clusterRegion, metadata.runnerType,
      runDate, metadata.iterationCount,
      metadata.infrastructureProvisioningSeconds,
      metadata.appDeploySeconds,
      metadata.lbReadySeconds,
      metadata.totalTestSuiteDurationSeconds,
      ...costCols,
    ]);
  }

  return rows.map(csvRow).join('\n') + '\n';
}

// ── Main ───────────────────────────────────────────────────────────────────────
fs.mkdirSync(OUT_DIR, { recursive: true });

const runs = findRunDirs();
if (runs.length === 0) {
  console.error(`No run directories found under ${METRICS_DIR}`);
  process.exit(1);
}
console.log(`Found ${runs.length} run(s): ${runs.map(r => `${r.cloud}/${r.runId}`).join(', ')}`);

const summaryPath = path.join(OUT_DIR, 'summary.csv');
fs.writeFileSync(summaryPath, buildSummaryCSV(runs));
console.log(`Wrote: ${summaryPath}`);

const rawPath = path.join(OUT_DIR, 'raw.csv');
fs.writeFileSync(rawPath, buildRawCSV(runs));
console.log(`Wrote: ${rawPath}`);

const runsPath = path.join(OUT_DIR, 'runs.csv');
fs.writeFileSync(runsPath, buildRunsCSV(runs));
console.log(`Wrote: ${runsPath}`);
