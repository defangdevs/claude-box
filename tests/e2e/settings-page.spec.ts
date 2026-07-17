// Browser e2e test for the per-user settings page (issue #36), driving a
// real Chromium against a live instance. Complements tests/settings-page.nix
// (which curls the HTTP surface inside a VM) by covering what only a browser
// exercises:
//   - the cookie leg of the Caddy route (__Host- cookie set on first
//     basic-auth response, then honored WITHOUT credentials),
//   - the HTML5 key-name validation on the form,
//   - the confirm() guards on Delete and Restart (dismiss + accept),
//   - the full save/list/delete flow, asserting the secret VALUE never
//     appears in any served HTML,
//   - (on-box only) env file mode 0600 + content, and the restart actually
//     killing the agent's tmux session.
//
// Each test is self-contained (creates and cleans up its own uniquely-named
// key): Playwright restarts the worker after a failure, so tests must not
// share in-process state.
//
// See playwright.config.ts for the E2E_* environment contract.

import { test, expect, Browser, Page, Locator } from '@playwright/test';
import { execFileSync } from 'child_process';
import * as fs from 'fs';

const USER = process.env.E2E_USER || 'claude';
const PASSWORD = process.env.E2E_PASSWORD || '';
const SETTINGS_PATH = `/${USER}/settings/`;

const ENV_FILE = process.env.E2E_ENV_FILE;
const TMUX_BIN = process.env.E2E_TMUX_BIN;
const TMUX_SOCKET = process.env.E2E_TMUX_SOCKET || 'agent-box';
const TMUX_SESSION = process.env.E2E_TMUX_SESSION || 'main';
const TMUX_TMPDIR = process.env.E2E_TMUX_TMPDIR;

// Unique per call so a leftover key from an aborted run can't cause a false
// pass, and so we never clobber a real key on a deployed box.
let seq = 0;
const uniqueKey = () =>
  `E2E_TEST_${Date.now().toString(36).toUpperCase()}_${seq++}`;

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

// The add/update form. Rows in the key list carry their own hidden
// input[name=key], so all form interactions must be scoped here.
function addForm(page: Page): Locator {
  return page.locator('form[action$="/settings/set"]');
}

// The secret editor collapses on load when JS is live; the header button
// toggles it. Open it only if needed (a second click would close it again).
async function openSecretEditor(page: Page) {
  if (await page.locator('#secret-editor').isHidden()) {
    await page.getByRole('button', { name: 'Add secret' }).click();
  }
}

async function saveKey(page: Page, key: string, value: string) {
  await openSecretEditor(page);
  await addForm(page).locator('input[name="key"]').fill(key);
  await addForm(page).locator('input[name="value"]').fill(value);
  await addForm(page).getByRole('button', { name: 'Save' }).click();
  await expect(page.locator('.msg')).toHaveText(/Key saved/);
}

async function deleteKey(page: Page, key: string) {
  page.once('dialog', (d) => d.accept());
  await page
    .locator('li', { hasText: key })
    .getByRole('button', { name: 'Delete' })
    .click();
  await expect(page.locator('li', { hasText: key })).toHaveCount(0);
}

function tmuxSessionAlive(): boolean {
  try {
    execFileSync(TMUX_BIN!, ['-L', TMUX_SOCKET, 'has-session', '-t', TMUX_SESSION], {
      env: { ...process.env, TMUX_TMPDIR: TMUX_TMPDIR || '' },
      stdio: 'pipe',
    });
    return true;
  } catch {
    return false;
  }
}

test('unauthenticated request is rejected with 401', async ({ request }) => {
  const res = await request.get(SETTINGS_PATH);
  expect(res.status()).toBe(401);
});

test('basic auth renders the page and sets the auth cookie; cookie alone then suffices', async ({ browser }) => {
  const ctx = await browser.newContext({
    httpCredentials: { username: USER, password: PASSWORD },
  });
  const page = await ctx.newPage();
  await page.goto(SETTINGS_PATH);
  await expect(page.getByRole('heading', { name: `Settings for ${USER}` })).toBeVisible();

  const cookie = (await ctx.cookies()).find((c) =>
    c.name.startsWith('__Host-agent_box_auth_')
  );
  expect(cookie, 'first authenticated response should set the __Host- auth cookie').toBeTruthy();

  // A fresh context with ONLY the cookie (no basic-auth credentials) must get
  // through — this is the leg the VM test cannot cover.
  const cookieCtx = await browser.newContext();
  await cookieCtx.addCookies([
    { name: cookie!.name, value: cookie!.value, url: process.env.E2E_BASE_URL! },
  ]);
  const cookiePage = await cookieCtx.newPage();
  const res = await cookiePage.goto(SETTINGS_PATH);
  expect(res!.status()).toBe(200);
  await expect(cookiePage.getByRole('heading', { name: `Settings for ${USER}` })).toBeVisible();
});

test('update status reports available commits and links to the GitHub changes', async ({ browser }) => {
  const page = await authedPage(browser);
  const head = '1111111111111111111111111111111111111111';
  await page.route('https://api.github.com/repos/**/compare/**', async (route) => {
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        status: 'ahead',
        ahead_by: 3,
        head_commit: { sha: head },
      }),
    });
  });

  await page.goto(SETTINGS_PATH);
  const status = page.locator('#update-status');
  await expect(status).toHaveAttribute('data-state', 'available');
  await expect(status).toContainText('agent-box update available — 3 commits.');
  const changes = status.getByRole('link', { name: 'View changes' });
  await expect(changes).toHaveAttribute('href', new RegExp(`/compare/.+\\.\\.\\.${head}$`));
});

test('secret value input is a password field', async ({ browser }) => {
  const page = await authedPage(browser);
  await page.goto(SETTINGS_PATH);
  await expect(addForm(page).locator('input[name="value"]')).toHaveAttribute('type', 'password');
});

test('HTML5 validation blocks an invalid key name', async ({ browser }) => {
  const page = await authedPage(browser);
  await page.goto(SETTINGS_PATH);
  await openSecretEditor(page);
  await addForm(page).locator('input[name="key"]').fill('1BAD-NAME');
  await addForm(page).locator('input[name="value"]').fill('whatever');
  await addForm(page).getByRole('button', { name: 'Save' }).click();
  // The pattern attribute must stop submission client-side: still on the
  // page, no success message, input flagged invalid.
  await expect(addForm(page).locator('input[name="key"]:invalid')).toHaveCount(1);
  await expect(page.locator('.msg')).toHaveCount(0);
});

test('saving a key lists its NAME and never its value; re-saving replaces', async ({ browser }) => {
  const key = uniqueKey();
  const value = `e2e-secret-${key}`;
  const page = await authedPage(browser);
  await page.goto(SETTINGS_PATH);

  await saveKey(page, key, value);
  await expect(page.locator('li', { hasText: key })).toHaveCount(1);
  expect(await page.content()).not.toContain(value);

  // Saving the same key again must replace, not duplicate.
  await saveKey(page, key, value + '-2');
  await expect(page.locator('li', { hasText: key })).toHaveCount(1);
  expect(await page.content()).not.toContain(value);

  // On-box: the env file is user-owned 0600 and holds the REPLACED value.
  if (ENV_FILE) {
    const st = fs.statSync(ENV_FILE);
    expect(st.mode & 0o777).toBe(0o600);
    const content = fs.readFileSync(ENV_FILE, 'utf-8');
    expect(content).toContain(`${key}=${value}-2`);
    expect(content).not.toContain(`${key}=${value}\n`);
  }

  await deleteKey(page, key);
});

test('pencil opens the editor with the key prefilled read-only; saving replaces the value', async ({ browser }) => {
  const key = uniqueKey();
  const page = await authedPage(browser);
  await page.goto(SETTINGS_PATH);
  await saveKey(page, key, 'before-edit');

  await page.locator(`button[data-edit="${key}"]`).click();
  const keyInput = addForm(page).locator('input[name="key"]');
  await expect(keyInput).toHaveValue(key);
  expect(await keyInput.evaluate((el: HTMLInputElement) => el.readOnly)).toBe(true);
  await addForm(page).locator('input[name="value"]').fill('after-edit');
  await addForm(page).getByRole('button', { name: 'Save' }).click();
  await expect(page.locator('.msg')).toHaveText(/Key saved/);
  await expect(page.locator('li', { hasText: key })).toHaveCount(1);

  if (ENV_FILE) {
    expect(fs.readFileSync(ENV_FILE, 'utf-8')).toContain(`${key}=after-edit`);
  }
  await deleteKey(page, key);
});

test('SPA layer: saving and deleting never triggers a full page load', async ({ browser }) => {
  const key = uniqueKey();
  const page = await authedPage(browser);
  await page.goto(SETTINGS_PATH);
  await page.evaluate(() => { (window as any).__noReloadMarker = true; });

  await saveKey(page, key, 'spa-check');
  await deleteKey(page, key);

  expect(await page.evaluate(() => (window as any).__noReloadMarker)).toBe(true);
});

test('dismissing the delete confirm keeps the key; accepting removes it', async ({ browser }) => {
  const key = uniqueKey();
  const page = await authedPage(browser);
  await page.goto(SETTINGS_PATH);
  await saveKey(page, key, 'to-be-deleted');
  const row = page.locator('li', { hasText: key });

  page.once('dialog', (d) => d.dismiss());
  await row.getByRole('button', { name: 'Delete' }).click();
  await expect(row).toHaveCount(1);

  page.once('dialog', (d) => d.accept());
  await row.getByRole('button', { name: 'Delete' }).click();
  await expect(page.locator('.msg')).toHaveText(/Key deleted/);
  await expect(row).toHaveCount(0);

  if (ENV_FILE) {
    expect(fs.readFileSync(ENV_FILE, 'utf-8')).not.toContain(key);
  }
});

test('restart is confirm-guarded and kills the agent tmux session', async ({ browser }) => {
  const page = await authedPage(browser);
  await page.goto(SETTINGS_PATH);
  const restart = page.getByRole('button', { name: 'Restart all' });

  if (TMUX_BIN) {
    expect(tmuxSessionAlive(), 'agent tmux session should be alive before the test').toBe(true);
  }

  // Dismissed confirm must be a no-op.
  page.once('dialog', (d) => d.dismiss());
  await restart.click();
  if (TMUX_BIN) expect(tmuxSessionAlive()).toBe(true);

  page.once('dialog', (d) => d.accept());
  await restart.click();
  await expect(page.locator('.msg')).toHaveText(/Restart of all sessions requested/);

  if (TMUX_BIN) {
    await expect.poll(tmuxSessionAlive, { timeout: 10_000 }).toBe(false);
  }
});
