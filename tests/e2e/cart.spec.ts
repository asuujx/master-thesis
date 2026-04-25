import test, { expect } from "@playwright/test";
import { CartPage } from "../pages/CartPage";
import { HomePage } from "../pages/HomePage";
import { withMetrics } from "../support/metrics";

test.describe("Cart", () => {
  let homePage: HomePage;
  let cartPage: CartPage;

  test.beforeEach(async ({ page }) => {
    homePage = new HomePage(page);
    cartPage = new CartPage(page);
  });

  test("should add a product to the cart", async ({ page }, testInfo) => {
    await withMetrics(page, testInfo, async () => {
      await homePage.goto();
      await homePage.addProductToCartByIndex(0);

      await expect(page).toHaveURL("/cart");
      expect(await cartPage.getCartItemCount()).toBe(1);
    });
  });

  test("should clear the cart", async ({ page }, testInfo) => {
    await withMetrics(page, testInfo, async () => {
      await homePage.goto();
      await homePage.addProductToCartByIndex(0);

      await homePage.goto();
      await homePage.addProductToCartByIndex(1);

      await cartPage.goto();
      await cartPage.clearCart();

      await cartPage.goto();
      expect(await cartPage.isCartEmpty()).toBe(true);
    });
  });
});
