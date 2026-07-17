// Root workspace e2e (tabbed sessions, issue 119; auth shape from 56/59).
//
// The vhost root is the primary user's tabbed terminal workspace, served by
// the settings daemon behind the same cookie-or-basic auth as the terminal:
// a tab per session, each pane an iframe onto the per-session ttyd URL.
// Complements tests/sessions.nix (which curls the HTTP surface inside a VM)
// by covering the browser-only legs:
//   - the auth gate on / (401 unauthenticated; basic auth renders the page),
//   - the active tab's pane iframing /<user>/?arg=<session> with no URL
//     userinfo (issue 56: Chrome answers the basic-auth challenge with
//     userinfo plus an EMPTY password, and typed credentials can't override),
//   - client-side tab switching that keeps background panes mounted,
//   - the add-session flow from the tab bar (new tab appears and activates),
//   - session restart/delete on the settings page, incl. the confirm() guard.
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

// The session editor collapses on load when JS is live; a toggle button
// opens it. Open it only if needed (a second click would close it again).
async function openSessionEditor(page: Page, buttonName: string) {
  if (await page.locator('#session-editor').isHidden()) {
    await page.getByRole('button', { name: buttonName }).click();
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

test('authenticated root shows the tab bar with main active and its terminal iframe', async ({ browser }) => {
  const page = await authedPage(browser);
  await page.goto('/');
  const mainTab = page.locator('#tab-bar .tab[data-tab="main"]');
  await expect(mainTab).toBeVisible();
  await expect(mainTab).toHaveAttribute('aria-current', 'page');
  // The pane may briefly be a "starting" placeholder; the poller swaps in
  // the iframe once the session is live.
  const frame = page.locator(`#panes iframe[src="/${USER}/?arg=main"]`);
  await expect(frame).toBeVisible({ timeout: 30_000 });
});

test('?tab= selects a tab server-side (the no-JS switching path)', async ({ browser }) => {
  const page = await authedPage(browser);
  await page.goto('/?tab=main');
  await expect(page.locator('#tab-bar .tab[data-tab="main"]')).toHaveAttribute('aria-current', 'page');
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

test('add a session from the tab bar, switch tabs, delete it on the settings page', async ({ browser }) => {
  const name = uniqueSession();
  const page = await authedPage(browser);
  await page.goto('/');

  // Add: the new tab appears, becomes active, and gets a pane.
  await openSessionEditor(page, 'New session');
  await page.locator('#session-editor input[name="name"]').fill(name);
  await page.locator('#session-editor button[type="submit"]').click();
  const newTab = page.locator(`#tab-bar .tab[data-tab="${name}"]`);
  await expect(newTab).toHaveAttribute('aria-current', 'page');
  await expect(page.locator(`#panes iframe[src="/${USER}/?arg=${name}"]`))
    .toBeVisible({ timeout: 30_000 });

  // Switch back to main: its pane shows, the new pane stays mounted but
  // hidden (background sessions keep their terminal attached).
  await page.locator('#tab-bar .tab[data-tab="main"]').click();
  await expect(page.locator('#tab-bar .tab[data-tab="main"]')).toHaveAttribute('aria-current', 'page');
  await expect(newTab).not.toHaveAttribute('aria-current', 'page');
  await expect(page.locator(`#panes .pane[data-pane="${name}"]`)).toHaveCount(1);
  await expect(page.locator(`#panes .pane[data-pane="${name}"]`)).not.toBeVisible();
  await expect(page.locator(`#panes iframe[src="/${USER}/?arg=main"]`))
    .toBeVisible({ timeout: 30_000 });

  // Delete lives on the settings page now. Dismissed confirm is a no-op;
  // accepting delists and kills the session.
  await page.goto(`/${USER}/settings/`);
  const row = page.locator('#sessions-list li', { hasText: name });
  await expect(row).toHaveCount(1);
  page.once('dialog', (d) => d.dismiss());
  await row.getByRole('button', { name: 'Delete' }).click();
  await expect(row).toHaveCount(1);
  page.once('dialog', (d) => d.accept());
  await row.getByRole('button', { name: 'Delete' }).click();
  await expect(page.locator('.msg')).toHaveText(/Session deleted/);
  await expect(row).toHaveCount(0);
});

test('settings link on the root page reaches the settings page, which manages sessions', async ({ browser }) => {
  const page = await authedPage(browser);
  await page.goto('/');
  await page.locator(`#tab-bar a[href="/${USER}/settings/"]`).click();
  await expect(page.getByRole('heading', { name: `Settings for ${USER}` })).toBeVisible();
  // The session manager moved here from the old root list page (issue 119).
  await expect(page.locator('#session-editor')).toHaveCount(1);
  await expect(page.getByRole('heading', { name: 'Sessions', exact: true })).toBeVisible();
});

test('settings page links to the agent-box repository', async ({ browser }) => {
  const page = await authedPage(browser);
  await page.goto(`/${USER}/settings/`);
  const repo = page.getByRole('link', { name: 'agent-box on GitHub' });
  await expect(repo).toBeVisible();
  await expect(repo).toHaveAttribute('href', 'https://github.com/defangdevs/agent-box');
});
