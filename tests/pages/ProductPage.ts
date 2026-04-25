import { Page } from "@playwright/test";
import { BasePage } from "./BasePage";

export class ProductPage extends BasePage {
  readonly productImageSelector = "img.product-image";
  readonly productInfoSelector = "div.product-info";
  readonly addToCartButtonSelector = 'button[type="submit"]';

  constructor(page: Page) {
    super(page);
  }

  async areProductDetailsVisible(): Promise<boolean> {
    const imageVisible = await this.page
      .locator(this.productImageSelector)
      .isVisible();
    const infoVisible = await this.page
      .locator(this.productInfoSelector)
      .isVisible();
    return imageVisible && infoVisible;
  }

  async addToCart() {
    await this.click(this.addToCartButtonSelector);
  }
}
