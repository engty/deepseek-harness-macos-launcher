/** Launcher-maintained 1024 Store. No background update requests. */
export const DEFAULT_UPDATE_URL = 'https://deepseek1024.com/api/v1/self/update';
export const CURRENT_VERSION = '0.5.0';
export async function checkForUpdate() {
    return {
        checked: true,
        currentVersion: CURRENT_VERSION,
        latestVersion: CURRENT_VERSION,
        updateAvailable: false,
        managedByLauncher: true,
    };
}
