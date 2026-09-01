import { test, expect } from '@playwright/test';

test('login and reach routes page', async ({ page }) => {
  await page.goto('/#/login');

  await expect(page.getByRole('heading', { name: 'Welcome to HydraSRT' })).toBeVisible();

  await page.getByPlaceholder('Username').fill('admin');
  await page.getByPlaceholder('Password').fill('password123');
  await page.getByRole('button', { name: 'Sign In' }).click();

  await expect(page).toHaveURL(/#\/routes/);
  await expect(page.getByRole('heading', { name: 'Routes' })).toBeVisible();
});

test('shows error alert when credentials are rejected', async ({ page }) => {
  await page.goto('/#/login');

  await page.getByPlaceholder('Username').fill('admin');
  await page.getByPlaceholder('Password').fill('wrong-password');
  await page.getByRole('button', { name: 'Sign In' }).click();

  const loginError = page.locator('[data-testid="login-error"]');
  await expect(loginError).toBeVisible();
  await expect(loginError).toHaveText('Invalid username or password');

  await expect(page).toHaveURL(/#\/login/);
  await expect(page.getByPlaceholder('Password')).toHaveValue('');
  await expect(page.getByPlaceholder('Username')).toHaveValue('admin');
});
