import { Page } from "@playwright/test";
import { BasePage } from "./BasePage";

export class CartPage extends BasePage {
  readonly cartItemSelector = ".cart-summary-item-row";
  readonly clearCartButtonSelector = "button.cart-summary-empty-cart-button";
  readonly emptyCartSectionSelector = "section.empty-cart-section";

  constructor(page: Page) {
    super(page);
  }

  async goto() {
    await this.page.goto("/cart");
  }

  async getCartItemCount() {
    return await this.page.locator(this.cartItemSelector).count();
  }

  async isCartEmpty() {
    return await this.page.locator(this.emptyCartSectionSelector).isVisible();
  }

  async clearCart() {
    await this.click(this.clearCartButtonSelector);
  }

  async navigateToCheckout() {
    await this.page.getByRole("link", { name: /checkout|cart/i }).click();
  }
}
