// Root sessions page e2e (replaces the unauthenticated picker; issues 56/59).
//
// The vhost root is the primary user's session manager, served by the
// settings daemon behind the same cookie-or-basic auth as the terminal.
// Complements tests/sessions.nix (which curls the HTTP surface inside a VM)
// by covering the browser-only legs:
//   - the auth gate on / (401 unauthenticated; basic auth renders the page),
//   - session cards deep-linking the terminal via ?arg= with no URL userinfo
//     (issue 56: Chrome answers the basic-auth challenge with userinfo plus
//     an EMPTY password, and typed credentials can't override it),
//   - the add/delete session round-trip through the UI, including the
//     confirm() guard on Delete.
//
// See playwright.config.ts for the E2E_* environment contract.

import { test, expect, Browser, Page } from '@playwright/test';

const USER = process.env.E2E_USER || 'claude';
const PASSWORD = process.env.E2E_PASSWORD || '';

// Unique per call so a leftover session from an aborted run can't cause a
// false pass. Session-name charset is [A-Za-z0-9_-].
let seq = 0;
const uniqueSession = () =>
  `e2e-${Date.now().toString(36)}-${seq++}`;

test.beforeAll(() => {
  if (!process.env.E2E_BASE_URL) throw new Error('E2E_BASE_URL is required');
  if (!PASSWORD) throw new Error('E2E_PASSWORD is required');
});

async function authedPage(browser: Browser): Promise<Page> {
  const ctx = await browser.newContext({
    httpCredentials: { username: USER, password: PASSWORD },
  });
  return ctx.newPage();
}

// The session editor collapses on load when JS is live; the header button
// toggles it. Open it only if needed (a second click would close it again).
async function openSessionEditor(page: Page) {
  if (await page.locator('#session-editor').isHidden()) {
    await page.locator('.sec-head').getByRole('button', { name: 'Add session' }).click();
  }
}

test('root requires auth: unauthenticated request is rejected with 401', async ({ request }) => {
  const res = await request.get('/');
  expect(res.status()).toBe(401);
});

test('the old public sessions.json is gone (now behind the auth gate)', async ({ request }) => {
  const res = await request.get(`/${USER}/sessions.json`);
  expect(res.status()).toBe(401);
});

test('authenticated root lists sessions with ?arg= terminal deep links', async ({ browser }) => {
  const page = await authedPage(browser);
  await page.goto('/');
  await expect(page.getByRole('heading', { level: 1, name: 'Agent Box' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Sessions', exact: true })).toBeVisible();
  const link = page.locator(`#sessions-list a.sess[href*="/${USER}/?arg="]`).first();
  await expect(link).toBeVisible();
});

test('authenticated root links to the agent-box repository', async ({ browser }) => {
  const page = await authedPage(browser);
  await page.goto('/');
  const repo = page.getByRole('link', { name: 'agent-box on GitHub' });
  await expect(repo).toBeVisible();
  await expect(repo).toHaveAttribute('href', 'https://github.com/defangdevs/agent-box');
});

test('no root-page href embeds URL userinfo (user@host)', async ({ browser }) => {
  const page = await authedPage(browser);
  await page.goto('/');
  const body = await page.content();
  const hrefs = [...body.matchAll(/href="([^"]*)"/g)].map((m) => m[1]);
  expect(hrefs.length).toBeGreaterThan(0);
  for (const href of hrefs) {
    expect(href, `userinfo in root-page link: ${href}`).not.toMatch(/^https?:\/\/[^/]*@/);
  }
});

test('add and delete a session through the root page', async ({ browser }) => {
  const name = uniqueSession();
  const page = await authedPage(browser);
  await page.goto('/');

  await openSessionEditor(page);
  await page.locator('#session-editor input[name="name"]').fill(name);
  await page.locator('#session-editor button[type="submit"]').click();
  await expect(page.locator('.msg')).toHaveText(/Session added/);
  const row = page.locator('li', { hasText: name });
  await expect(row).toHaveCount(1);

  // Dismissed confirm must be a no-op; accepting delists and kills it.
  page.once('dialog', (d) => d.dismiss());
  await row.getByRole('button', { name: 'Delete' }).click();
  await expect(row).toHaveCount(1);

  page.once('dialog', (d) => d.accept());
  await row.getByRole('button', { name: 'Delete' }).click();
  await expect(page.locator('.msg')).toHaveText(/Session deleted/);
  await expect(row).toHaveCount(0);
});

test('settings link on the root page reaches the settings page', async ({ browser }) => {
  const page = await authedPage(browser);
  await page.goto('/');
  await page.locator(`a[href="/${USER}/settings/"]`).click();
  await expect(page.getByRole('heading', { name: `Settings for ${USER}` })).toBeVisible();
  // The session manager moved to /: the settings page must not render it.
  await expect(page.locator('#session-editor')).toHaveCount(0);
});
