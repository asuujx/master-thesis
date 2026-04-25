import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./tests/e2e",
  fullyParallel: false,
  retries: 0,
  workers: 1,
  reporter: [
    ["html"],
    ["json", { outputFile: "results/results.json" }],
    ["list"],
  ],
  use: {
    baseURL: process.env.BASE_URL || "http://localhost:8080",
    trace: "on",
    screenshot: "only-on-failure",
    video: "retain-on-failure",
  },

  /* Configure projects for major browsers */
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
