import fs from "fs";
import path from "path";
import { Page, TestInfo } from "@playwright/test";

export interface PageMetrics {
  // Test metadata
  testName: string;
  url: string;
  environment: string;
  cloud: string;
  timestamp: string;
  iteration: number;
  attemptNumber: number;
  passed: boolean;
  errorMessage?: string;

  // Test-level
  testDuration: number;

  // Navigation timing — absolute (ms from navigationStart)
  ttfb: number;
  domInteractive: number;
  domContentLoaded: number;
  loadComplete: number;

  // Navigation timing — phase breakdown (ms each phase took)
  redirectTime: number;
  dnsLookup: number;
  tcpConnect: number;
  tlsHandshake: number;      // 0 on plain HTTP
  serverProcessing: number;  // responseStart - requestStart
  contentDownload: number;   // responseEnd - responseStart

  // Document transfer
  transferSize: number;           // compressed bytes over the wire
  encodedBodySize: number;
  decodedBodySize: number;

  // Resource aggregates (all sub-resources: JS, CSS, images, …)
  resourceCount: number;
  totalResourceTransferSize: number;

  // Core Web Vitals
  fcp: number;   // First Contentful Paint (ms)
  lcp: number;   // Largest Contentful Paint (ms)
  cls: number;   // Cumulative Layout Shift (unitless, 3 decimal places)
  tbt: number;   // Total Blocking Time (ms, sum of long-task blocking beyond 50 ms)
  inp: number;   // Interaction to Next Paint (ms, -1 if no interactions recorded)

  // Memory — Chromium only; -1 when unavailable
  jsHeapUsed: number;
  jsHeapTotal: number;
}

export class MetricsCollector {
  private startTime = 0;

  constructor(
    private page: Page,
    private testInfo: TestInfo,
  ) {}

  async setup() {
    this.startTime = Date.now();

    // Inject observers into every document the page loads so they are in place
    // before the first navigation, not after. Without this, LCP / CLS / TBT are
    // always missed because the entries have already fired.
    await this.page.addInitScript(() => {
      (window as any).__pw_metrics = { lcp: -1, cls: 0, tbt: 0, inpValues: [] as number[] };

      try {
        new PerformanceObserver((list) => {
          const entries = list.getEntries();
          if (entries.length) {
            (window as any).__pw_metrics.lcp = Math.round(
              entries[entries.length - 1].startTime,
            );
          }
        }).observe({ type: "largest-contentful-paint", buffered: true });
      } catch {}

      try {
        new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) {
            if (!(entry as any).hadRecentInput) {
              (window as any).__pw_metrics.cls += (entry as any).value;
            }
          }
        }).observe({ type: "layout-shift", buffered: true });
      } catch {}

      try {
        new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) {
            (window as any).__pw_metrics.tbt += Math.max(0, entry.duration - 50);
          }
        }).observe({ type: "longtask", buffered: true });
      } catch {}

      try {
        new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) {
            (window as any).__pw_metrics.inpValues.push(entry.duration);
          }
        }).observe({ type: "event", durationThreshold: 16, buffered: true } as any);
      } catch {}
    });
  }

  async collect(passed: boolean, errorMessage?: string): Promise<PageMetrics> {
    const testDuration = Date.now() - this.startTime;
    const url = this.page.url();

    const timing = await this.page.evaluate(() => {
      const nav = performance.getEntriesByType(
        "navigation",
      )[0] as PerformanceNavigationTiming;
      if (!nav) return null;

      const resources = performance.getEntriesByType(
        "resource",
      ) as PerformanceResourceTiming[];

      const pw = (window as any).__pw_metrics ?? {};
      const inpValues: number[] = pw.inpValues ?? [];
      const mem = (performance as any).memory;
      const fcpEntry = performance.getEntriesByName("first-contentful-paint")[0];

      return {
        // Absolute timings
        ttfb:             nav.responseStart              - nav.startTime,
        domInteractive:   nav.domInteractive             - nav.startTime,
        domContentLoaded: nav.domContentLoadedEventEnd   - nav.startTime,
        loadComplete:     nav.loadEventEnd               - nav.startTime,

        // Phase breakdown
        redirectTime:      nav.redirectEnd              - nav.redirectStart,
        dnsLookup:         nav.domainLookupEnd          - nav.domainLookupStart,
        tcpConnect:        nav.connectEnd               - nav.connectStart,
        tlsHandshake:      nav.secureConnectionStart > 0
                             ? nav.requestStart - nav.secureConnectionStart
                             : 0,
        serverProcessing:  nav.responseStart            - nav.requestStart,
        contentDownload:   nav.responseEnd              - nav.responseStart,

        // Transfer
        transferSize:    nav.transferSize,
        encodedBodySize: nav.encodedBodySize,
        decodedBodySize: nav.decodedBodySize,

        // Resources
        resourceCount:             resources.length,
        totalResourceTransferSize: resources.reduce((s, r) => s + (r.transferSize ?? 0), 0),

        // Core Web Vitals
        fcp: fcpEntry ? Math.round(fcpEntry.startTime) : -1,
        lcp: pw.lcp ?? -1,
        cls: Math.round((pw.cls ?? 0) * 1000) / 1000,
        tbt: Math.round(pw.tbt ?? 0),
        inp: inpValues.length > 0 ? Math.round(Math.max(...inpValues)) : -1,

        // Memory
        jsHeapUsed:  mem?.usedJSHeapSize  ?? -1,
        jsHeapTotal: mem?.totalJSHeapSize ?? -1,
      };
    });

    const cloud = process.env.CLOUD_PROVIDER ?? "local";
    const env   = process.env.ENVIRONMENT   ?? "local";

    const metrics: PageMetrics = {
      testName:    this.testInfo.title,
      url,
      environment: env,
      cloud,
      timestamp:   new Date().toISOString(),
      iteration:     parseInt(process.env.ITERATION ?? "1"),
      attemptNumber: this.testInfo.retry + 1,
      passed,
      errorMessage,
      testDuration,
      ttfb:                      timing?.ttfb                      ?? -1,
      domInteractive:            timing?.domInteractive            ?? -1,
      domContentLoaded:          timing?.domContentLoaded          ?? -1,
      loadComplete:              timing?.loadComplete              ?? -1,
      redirectTime:              timing?.redirectTime              ?? -1,
      dnsLookup:                 timing?.dnsLookup                 ?? -1,
      tcpConnect:                timing?.tcpConnect                ?? -1,
      tlsHandshake:              timing?.tlsHandshake              ?? -1,
      serverProcessing:          timing?.serverProcessing          ?? -1,
      contentDownload:           timing?.contentDownload           ?? -1,
      transferSize:              timing?.transferSize              ?? -1,
      encodedBodySize:           timing?.encodedBodySize           ?? -1,
      decodedBodySize:           timing?.decodedBodySize           ?? -1,
      resourceCount:             timing?.resourceCount             ?? -1,
      totalResourceTransferSize: timing?.totalResourceTransferSize ?? -1,
      fcp:                       timing?.fcp                       ?? -1,
      lcp:                       timing?.lcp                       ?? -1,
      cls:                       timing?.cls                       ?? -1,
      tbt:                       timing?.tbt                       ?? -1,
      inp:                       timing?.inp                       ?? -1,
      jsHeapUsed:                timing?.jsHeapUsed                ?? -1,
      jsHeapTotal:               timing?.jsHeapTotal               ?? -1,
    };

    const resultsDir = "results";
    const filePath = path.join(resultsDir, `${cloud}_${env}.json`);
    fs.mkdirSync(resultsDir, { recursive: true });

    let existing: PageMetrics[] = [];
    if (fs.existsSync(filePath)) {
      existing = JSON.parse(fs.readFileSync(filePath, "utf-8"));
    }
    fs.writeFileSync(filePath, JSON.stringify([...existing, metrics], null, 2));

    await this.testInfo.attach(`${cloud}_${env}_${this.testInfo.title}.json`, {
      body: JSON.stringify(metrics, null, 2),
      contentType: "application/json",
    });

    return metrics;
  }
}

export async function withMetrics(
  page: Page,
  testInfo: TestInfo,
  fn: () => Promise<void>,
): Promise<PageMetrics> {
  const collector = new MetricsCollector(page, testInfo);
  await collector.setup();

  let passed = true;
  let errorMessage: string | undefined;
  let thrownError: unknown;

  try {
    await fn();
  } catch (err) {
    passed = false;
    errorMessage = err instanceof Error ? err.message : String(err);
    thrownError = err;
  }

  const metrics = await collector.collect(passed, errorMessage);

  if (thrownError) {
    throw thrownError;
  }

  return metrics;
}
