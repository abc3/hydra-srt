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
