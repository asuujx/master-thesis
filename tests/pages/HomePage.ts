import { Page } from "@playwright/test";
import { BasePage } from "./BasePage";

export class HomePage extends BasePage {
  readonly productCardSelector = ".hot-product-card";

  constructor(page: Page) {
    super(page);
  }

  async goto() {
    await this.page.goto("/");
  }

  async clickProductByIndex(index: number) {
    await this.page.locator(this.productCardSelector).nth(index).click();
  }

  async getProductCount() {
    return await this.page.locator(this.productCardSelector).count();
  }

  async addProductToCartByIndex(index: number) {
    await this.clickProductByIndex(index);
    await this.click('button[type="submit"]');
  }
}
