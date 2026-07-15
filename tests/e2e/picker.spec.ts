// Root picker regression tests (issue 56).
//
// The picker (and the CFN WebURL output) must never embed URL userinfo
// (https://user@host/...): Chrome answers the basic-auth challenge with the
// userinfo username plus an EMPTY password, and credentials typed into the
// prompt cannot override the URL-embedded identity — locking users out of
// the terminal with the "correct password".

import { test, expect } from '@playwright/test';

const USER = process.env.E2E_USER || 'claude';

test('root picker serves unauthenticated and links the terminal', async ({ request }) => {
  const res = await request.get('/');
  expect(res.status()).toBe(200);
  const body = await res.text();
  expect(body).toContain(`href="https://`);
  expect(body).toContain(`/${USER}/"`);
});

test('no picker href embeds URL userinfo (user@host)', async ({ request }) => {
  const body = await (await request.get('/')).text();
  const hrefs = [...body.matchAll(/href="([^"]*)"/g)].map((m) => m[1]);
  expect(hrefs.length).toBeGreaterThan(0);
  for (const href of hrefs) {
    expect(href, `userinfo in picker link: ${href}`).not.toMatch(/^https?:\/\/[^/]*@/);
  }
});

// Flat session picker (issue 59): the page fetches each user's public
// sessions.json and renders one card per SESSION deep-linking into the
// terminal via ttyd's ?arg= session selector.
test('picker lists sessions with ?arg= deep links', async ({ page }) => {
  await page.goto('/');
  const card = page.locator(`#list a.term[href*="/${USER}/?arg="]`).first();
  await expect(card).toBeVisible();
  const href = await card.getAttribute('href');
  expect(href, `userinfo in session link: ${href}`).not.toMatch(/^https?:\/\/[^/]*@/);
});

test('public sessions.json lists names and agents only', async ({ request }) => {
  const res = await request.get(`/${USER}/sessions.json`);
  expect(res.status()).toBe(200);
  const sessions = await res.json();
  expect(Array.isArray(sessions)).toBe(true);
  expect(sessions.length).toBeGreaterThan(0);
  for (const s of sessions) {
    expect(Object.keys(s).sort()).toEqual(['agent', 'name']);
  }
});
