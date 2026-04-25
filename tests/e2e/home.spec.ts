import { expect, test } from "@playwright/test";
import { HomePage } from "../pages/HomePage";
import { ProductPage } from "../pages/ProductPage";
import { withMetrics } from "../support/metrics";

test.describe("Home page", () => {
  let homePage: HomePage;
  let productPage: ProductPage;

  test.beforeEach(async ({ page }) => {
    homePage = new HomePage(page);
    productPage = new ProductPage(page);
  });

  test("should load the home page and display products", async ({
    page,
  }, testInfo) => {
    await withMetrics(page, testInfo, async () => {
      await homePage.goto();

      await expect(page).toHaveTitle("Online Boutique");
      await expect(page.locator(homePage.productCardSelector)).toHaveCount(9);
    });
  });

  test("should navigate to product details page when a product is clicked", async ({
    page,
  }, testInfo) => {
    await withMetrics(page, testInfo, async () => {
      await homePage.goto();
      await homePage.clickProductByIndex(0);

      expect(await productPage.areProductDetailsVisible()).toBe(true);
    });
  });
});
