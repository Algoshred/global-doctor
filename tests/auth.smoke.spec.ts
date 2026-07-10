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
      test.skip('GRAPHQL_URL not configured');
    }
    const response = await request.fetch(url!, { method: 'OPTIONS' });
    expect([200, 204, 405]).toContain(response.status());
  });
});
