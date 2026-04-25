import { expect, test } from "@playwright/test";
import Chance from "chance";
import { CartPage } from "../pages/CartPage";
import { CheckoutPage, type CheckoutFormData } from "../pages/CheckoutPage";
import { HomePage } from "../pages/HomePage";
import { withMetrics } from "../support/metrics";

const chance = new Chance();

const formData: CheckoutFormData = {
  email: chance.email(),
  streetAddress: chance.address(),
  zipCode: chance.zip(),
  city: chance.city(),
  state: chance.state({ full: true }),
  country: chance.country({ full: true }),
  creditCardNumber: chance.cc({ type: "Visa" }),
  creditCardExpirationMonth: chance.month(),
  creditCardExpirationYear: chance.year({ min: 2026, max: 2037 }).toString(),
  creditCardCvv: chance.integer({ min: 100, max: 999 }).toString(),
};

test.describe("Checkout", () => {
  let homePage: HomePage;
  let cartPage: CartPage;
  let checkoutPage: CheckoutPage;

  test.beforeEach(async ({ page }) => {
    homePage = new HomePage(page);
    cartPage = new CartPage(page);
    checkoutPage = new CheckoutPage(page);
  });

  test("should display checkout form", async ({ page }, testInfo) => {
    await withMetrics(page, testInfo, async () => {
      await homePage.goto();
      await homePage.addProductToCartByIndex(0);
      await cartPage.navigateToCheckout();

      await expect(page.locator("#email")).toBeVisible();
    });
  });

  test("should complete full purchase", async ({ page }, testInfo) => {
    await withMetrics(page, testInfo, async () => {
      await homePage.goto();
      await homePage.addProductToCartByIndex(0);
      await cartPage.navigateToCheckout();

      await checkoutPage.fillCheckoutForm({
        ...formData,
      });

      await checkoutPage.submitCheckout();

      await expect(
        page.getByRole("heading", { name: "Your order is complete!" }),
      ).toBeVisible({ timeout: 15000 });
    });
  });
});
