import { test, expect } from '@playwright/test';

/**
 * Smoke test: admin console login page loads and exposes expected elements.
 *
 * This is a scaffold test. Real tests should authenticate through the Burdenoff
 * identity provider and exercise tenant / billing / notification admin flows.
 */
test.describe('global admin smoke', () => {
  test('admin login page renders', async ({ page }) => {
    await page.goto('/');
    // Expect the login form or admin shell to be present.
    await expect(page.locator('body')).toContainText(/sign in|login|admin/i, { timeout: 10_000 });
  });

  test('global GraphQL gateway responds to OPTIONS', async ({ request }) => {
    const url = process.env.GRAPHQL_URL;
    if (!url) {
      throw new Error('GRAPHQL_URL not configured');
    }
    // Send a real CORS preflight request so the gateway handles it as OPTIONS.
    const response = await request.fetch(url, {
      method: 'OPTIONS',
      headers: {
        Origin: process.env.ADMIN_URL || 'https://admin.burdenoff.com',
        'Access-Control-Request-Method': 'POST',
        'Access-Control-Request-Headers': 'Content-Type',
      },
    });
    expect([200, 204]).toContain(response.status());
  });
});
