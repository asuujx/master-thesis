#!/usr/bin/env node
'use strict';

// Aggregates metrics from all iteration-* subdirectories of a run folder into
// a single summary.json with mean, stddev, min, p50, p95, max per metric.
//
// Usage: node scripts/summarize.js <run-dir>
//   e.g. node scripts/summarize.js metrics/gcp/2026-05-04_08-59-05

const fs   = require('fs');
const path = require('path');

const runDir = process.argv[2];
if (!runDir) {
  console.error('Usage: node scripts/summarize.js <run-dir>');
  process.exit(1);
}

const absRunDir = path.resolve(runDir);
if (!fs.existsSync(absRunDir)) {
  console.error(`Directory not found: ${absRunDir}`);
  process.exit(1);
}

const NUMERIC_FIELDS = [
  'testDuration',
  'ttfb', 'domInteractive', 'domContentLoaded', 'loadComplete',
  'redirectTime', 'dnsLookup', 'tcpConnect', 'tlsHandshake',
  'serverProcessing', 'contentDownload',
  'transferSize', 'encodedBodySize', 'decodedBodySize',
  'resourceCount', 'totalResourceTransferSize',
  'fcp', 'lcp', 'cls', 'tbt', 'inp',
  'jsHeapUsed', 'jsHeapTotal',
];

function round2(v) {
  return Math.round(v * 100) / 100;
}

function percentile(sorted, p) {
  if (sorted.length === 1) return sorted[0];
  const idx = (p / 100) * (sorted.length - 1);
  const lo  = Math.floor(idx);
  const hi  = Math.ceil(idx);
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - lo);
}

function stats(values) {
  // -1 is the sentinel for "metric unavailable"; exclude from aggregation
  const valid = values.filter(v => typeof v === 'number' && v >= 0);
  if (valid.length === 0) return null;
  const sorted   = [...valid].sort((a, b) => a - b);
  const mean     = valid.reduce((s, v) => s + v, 0) / valid.length;
  const variance = valid.reduce((s, v) => s + (v - mean) ** 2, 0) / valid.length;
  return {
    mean:   round2(mean),
    stddev: round2(Math.sqrt(variance)),
    min:    round2(sorted[0]),
    p50:    round2(percentile(sorted, 50)),
    p95:    round2(percentile(sorted, 95)),
    max:    round2(sorted[sorted.length - 1]),
    n:      valid.length,
  };
}

// Collect iteration directories, sorted numerically
const iterDirs = fs.readdirSync(absRunDir)
  .filter(d => /^iteration-\d+$/.test(d))
  .sort((a, b) => parseInt(a.split('-')[1]) - parseInt(b.split('-')[1]));

if (iterDirs.length === 0) {
  console.error(`No iteration-* directories found in ${absRunDir}`);
  process.exit(1);
}

// Load all records from every iteration
const allRecords = [];
for (const iterDir of iterDirs) {
  const iterPath = path.join(absRunDir, iterDir);
  const jsonFiles = fs.readdirSync(iterPath)
    .filter(f => f.endsWith('.json') && !f.startsWith('artifacts-'));
  for (const jsonFile of jsonFiles) {
    const parsed = JSON.parse(fs.readFileSync(path.join(iterPath, jsonFile), 'utf-8'));
    const records = Array.isArray(parsed) ? parsed : [parsed];
    allRecords.push(...records);
  }
}

if (allRecords.length === 0) {
  console.error('No test records found in any iteration directory');
  process.exit(1);
}

// Group: testName → iteration → keep only the final attempt (highest attemptNumber).
// With retries enabled each attempt writes its own record; we want the final outcome
// for performance aggregation, while still counting flakiness separately.
const byTest = {};
for (const record of allRecords) {
  const name    = record.testName;
  const iter    = record.iteration    ?? 1;
  const attempt = record.attemptNumber ?? 1;
  if (!byTest[name])        byTest[name] = {};
  const prev = byTest[name][iter];
  if (!prev || attempt > (prev.attemptNumber ?? 1)) {
    byTest[name][iter] = record;
  }
}

const cloud       = allRecords[0].cloud;
const environment = allRecords[0].environment;

const tests = Object.entries(byTest).map(([testName, iterMap]) => {
  const finalAttempts = Object.values(iterMap);
  const flakyCount    = finalAttempts.filter(r => (r.attemptNumber ?? 1) > 1).length;
  const passCount     = finalAttempts.filter(r => r.passed).length;

  const metrics = {};
  for (const field of NUMERIC_FIELDS) {
    const s = stats(finalAttempts.map(r => r[field]));
    if (s) metrics[field] = s;
  }

  return {
    testName,
    url:            finalAttempts[0]?.url,
    iterationCount: finalAttempts.length,
    passCount,
    flakyCount,
    flakyRate:      round2(flakyCount / finalAttempts.length),
    metrics,
  };
});

const summary = {
  cloud,
  environment,
  iterationCount: iterDirs.length,
  generatedAt:    new Date().toISOString(),
  tests,
};

const outPath = path.join(absRunDir, 'summary.json');
fs.writeFileSync(outPath, JSON.stringify(summary, null, 2));
console.log(
  `Summary written to ${outPath}` +
  ` (${tests.length} test(s), ${iterDirs.length} iteration(s))`
);
