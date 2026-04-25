import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
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

  // Locally: spin up the stack automatically.
  // On a pipeline: BASE_URL points to the deployed app, skip this entirely.
  webServer: process.env.BASE_URL
    ? undefined
    : {
        command: "docker compose -f ../app/docker-compose.yml up",
        url: "http://localhost:8080",
        timeout: 120_000,
        reuseExistingServer: true,
        stdout: "pipe",
        stderr: "pipe",
      },

  /* Configure projects for major browsers */
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
