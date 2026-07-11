/**
 * Dashboard configuration.
 *
 * apiUrl: the GetInventory function endpoint, including its function key, e.g.
 *   "https://func-inventory-eastus.azurewebsites.net/api/GetInventory?code=XXXX"
 *
 * Leave apiUrl empty ("") to run in DEMO mode with bundled sample data -
 * useful for previewing the dashboard before anything is deployed.
 */
window.INVENTORY_CONFIG = {
  apiUrl: "",
  refreshSeconds: 60,
};
