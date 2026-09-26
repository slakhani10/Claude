/**
 * Dashboard configuration.
 *
 * apiUrl: the GetInventory function endpoint, including its function key, e.g.
 *   "https://func-inventory-eastus.azurewebsites.net/api/GetInventory?code=XXXX"
 *
 * reservationsApiUrl: the GetReservationSavings endpoint, same app, same key style:
 *   "https://func-inventory-eastus.azurewebsites.net/api/GetReservationSavings?code=XXXX"
 *
 * Leave either URL empty ("") to run that tab in DEMO mode with bundled sample
 * data - useful for previewing the dashboard before anything is deployed.
 *
 * refreshSeconds polls the servers feed only. The reservations tab loads when
 * first opened and then only on demand: its endpoint caches for hours, because
 * reservation costs move at most daily.
 */
window.INVENTORY_CONFIG = {
  apiUrl: "",
  reservationsApiUrl: "",
  refreshSeconds: 60,
};
