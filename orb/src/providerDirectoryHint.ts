import { jsonSignal } from "./storage";

export const PROVIDER_DIRECTORY_HINTS_KEY = "orb.providerDirectoryHints";
export const PROVIDER_DIRECTORY_HINTS_DEFAULT = true;
export const MOZHENZHEN_PROVIDER_URL = "https://mozhenzhen.com/go/orb";
export const MOZHENZHEN_PROVIDER_COPY = "Compare model prices & check API authenticity on Mozhenzhen";
export const PROVIDER_DIRECTORY_SETTING_TITLE = "Provider directory link";
export const PROVIDER_DIRECTORY_SETTING_DESC =
  "Show the Mozhenzhen model pricing and API authenticity link in provider setup.";

const isBoolean = (value: unknown): value is boolean => typeof value === "boolean";

export const [showProviderDirectoryHints, setShowProviderDirectoryHints] = jsonSignal<boolean>(
  PROVIDER_DIRECTORY_HINTS_KEY,
  PROVIDER_DIRECTORY_HINTS_DEFAULT,
  isBoolean,
);
