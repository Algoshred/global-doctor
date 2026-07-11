import { defineConfig, devices } from '@playwright/test';

/**
 * Global doctor — Playwright E2E configuration.
 *
 * Targets the admin console and global GraphQL gateway smoke tests.
 * URLs default to alpha; override with env vars.
 */
const adminUrl = process.env.ADMIN_URL || 'https://admin.burdenoff.com';
const graphqlUrl = process.env.GRAPHQL_URL || 'https://alphagraphql.burdenoff.com/global/graphql';

// Expose resolved URLs to tests via process.env (Playwright ignores the
// top-level `env` key, so we set it explicitly here).
process.env.ADMIN_URL = adminUrl;
process.env.GRAPHQL_URL = graphqlUrl;

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: adminUrl,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
    {
      name: 'Mobile Chrome',
      use: { ...devices['Pixel 7'] },
    },
  ],
  webServer: process.env.SERVE_LOCAL
    ? {
        command: 'cd ../../../admin/admin-app && bun run dev',
        url: 'http://localhost:5231',
        reuseExistingServer: !process.env.CI,
        timeout: 120_000,
      }
    : undefined,
});
