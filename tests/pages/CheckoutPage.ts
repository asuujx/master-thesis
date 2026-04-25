import { Page } from "@playwright/test";
import Chance from "chance";
import { BasePage } from "./BasePage";

export type CheckoutFormData = {
  email: string;
  streetAddress: string;
  zipCode: string;
  city: string;
  state: string;
  country: string;
  creditCardNumber: string;
  creditCardExpirationMonth: string;
  creditCardExpirationYear: string;
  creditCardCvv: string;
};

export class CheckoutPage extends BasePage {
  

  readonly emailSelector = "#email";
  readonly streetAddressSelector = "#street_address";
  readonly zipCodeSelector = "#zip_code";
  readonly citySelector = "#city";
  readonly stateSelector = "#state";
  readonly countrySelector = "#country";
  readonly creditCardNumberSelector = "#credit_card_number";
  readonly creditCardExpirationMonthSelector = "#credit_card_expiration_month";
  readonly creditCardExpirationYearSelector = "#credit_card_expiration_year";
  readonly creditCardCvvSelector = "#credit_card_cvv";

  constructor(page: Page) {
    super(page);
  }

  async fillCheckoutForm(formData: CheckoutFormData) {
    await this.fill(this.emailSelector, formData.email);
    await this.fill(this.streetAddressSelector, formData.streetAddress);
    await this.fill(this.zipCodeSelector, formData.zipCode);
    await this.fill(this.citySelector, formData.city);
    await this.fill(this.stateSelector, formData.state);
    await this.fill(this.countrySelector, formData.country);
    await this.fill(this.creditCardNumberSelector, formData.creditCardNumber);
    await this.selectOption(
      this.creditCardExpirationMonthSelector,
      formData.creditCardExpirationMonth,
    );
    await this.selectOption(
      this.creditCardExpirationYearSelector,
      formData.creditCardExpirationYear,
    );
    await this.fill(this.creditCardCvvSelector, formData.creditCardCvv);
  }

  async submitCheckout() {
    await this.page.getByRole("button", { name: "Place Order" }).click();
  }
}
