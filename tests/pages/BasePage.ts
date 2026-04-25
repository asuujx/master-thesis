import { Page } from "@playwright/test";

export class BasePage {
  readonly page: Page;

  constructor(page: Page) {
    this.page = page;
  }

  async click(selector: string) {
    await this.page.locator(selector).click();
  }

  async fill(selector: string, text: string) {
    await this.page.locator(selector).fill(text);
  }

  async selectOption(selector: string, label: string) {
    await this.page.locator(selector).selectOption({ label });
  }
}
