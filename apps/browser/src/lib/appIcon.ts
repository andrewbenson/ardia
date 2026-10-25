import { PRODUCT } from "./productName";

const FORK_ICONS: Record<string, number> = {
  Vista: require("../../assets/app-icon-vista.png"),
};

export const APP_ICON: number = FORK_ICONS[PRODUCT] ?? require("../../assets/app-icon.png");
