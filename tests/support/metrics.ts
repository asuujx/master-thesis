import { Page, TestInfo } from "@playwright/test";

export interface PageMetrics {
  testName: string;
  environment: string;
  cloud: string;
  timestamp: string;
  iteration: number;
  domContentLoaded: number;
  loadComplete: number;
  firstByte: number;
  fcp: number;
  lcp: number;
  testDuration: number;
  passed: boolean;
  errorMessage?: string;
}

export class MetricsCollector {
  private startTime: number = 0;

  constructor(
    private page: Page,
    private testInfo: TestInfo,
  ) {}

  startTimer() {
    this.startTime = Date.now();
  }

  async collect(passed: boolean, errorMessage?: string): Promise<PageMetrics> {
    const testDuration = Date.now() - this.startTime;

    const navTiming = await this.page.evaluate(() => {
      const nav = performance.getEntriesByType(
        "navigation",
      )[0] as PerformanceNavigationTiming;
      if (!nav) return null;
      return {
        domContentLoaded: nav.domContentLoadedEventEnd - nav.startTime,
        loadComplete: nav.loadEventEnd - nav.startTime,
        firstByte: nav.responseStart - nav.startTime,
      };
    });

    const fcp = await this.page.evaluate(() => {
      const entry = performance.getEntriesByName("first-contentful-paint")[0];
      return entry ? Math.round(entry.startTime) : -1;
    });

    const lcp = await this.page.evaluate(() => {
      return new Promise<number>((resolve) => {
        let lcpValue = -1;
        try {
          const observer = new PerformanceObserver((list) => {
            const entries = list.getEntries();
            lcpValue = Math.round(entries[entries.length - 1].startTime);
          });
          observer.observe({
            type: "largest-contentful-paint",
            buffered: true,
          });
          setTimeout(() => {
            observer.disconnect();
            resolve(lcpValue);
          }, 500);
        } catch {
          resolve(-1);
        }
      });
    });

    const metrics: PageMetrics = {
      testName: this.testInfo.title,
      environment: process.env.ENVIRONMENT || "local",
      cloud: process.env.CLOUD_PROVIDER || "local",
      timestamp: new Date().toISOString(),
      iteration: parseInt(process.env.ITERATION || "1"),
      domContentLoaded: navTiming?.domContentLoaded ?? -1,
      loadComplete: navTiming?.loadComplete ?? -1,
      firstByte: navTiming?.firstByte ?? -1,
      fcp,
      lcp,
      testDuration,
      passed,
      errorMessage,
    };

    // Playwright API do zapisu plików - działa po stronie Node.js runnera
    const cloud = process.env.CLOUD_PROVIDER || "local";
    const env = process.env.ENVIRONMENT || "local";
    const filename = `${cloud}_${env}.json`;

    // Odczytaj istniejące wyniki
    let existing: PageMetrics[] = [];
    try {
      const content = await this.testInfo.attach("read", { body: "" });
    } catch {}

    // Zapisz przez testInfo - trafia do results/
    await this.testInfo.attach(filename, {
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
  collector.startTimer();
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
