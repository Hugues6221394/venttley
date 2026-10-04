export const themePreferenceKey = "venttly-console-appearance-v1";
export type ThemePreference = "light" | "dark" | "system";
export function themePreference(value: unknown): ThemePreference {
  return value === "light" || value === "dark" ? value : "system";
}

// Constant program, never interpolated with a cookie, query, identity or source
// content. CSS handles the system preference (including live OS changes).
export const themeBootstrap = `(function(){var r=document.documentElement;if(r.dataset.themeUi!=="enabled")return;var p="system";try{var v=localStorage.getItem("venttly-console-appearance-v1");if(v==="light"||v==="dark")p=v;}catch(e){}r.dataset.theme=p;})();`;

export function bindThemePreference(win: Window, root: HTMLElement, changed: (value: ThemePreference) => void) {
  const apply = (value: unknown) => { const preference = themePreference(value); root.dataset.theme = preference; changed(preference); };
  // A storage failure must never prevent rendering or changing this tab.
  let initial = themePreference(root.dataset.theme);
  try { initial = themePreference(win.localStorage.getItem(themePreferenceKey)); } catch {}
  apply(initial);
  const onStorage = (event: StorageEvent) => {
    if(event.key !== themePreferenceKey && event.key !== null)return;
    try { if(event.storageArea !== win.localStorage)return; } catch { return; }
    apply(event.key === null ? "system" : event.newValue);
  };
  win.addEventListener("storage",onStorage);
  return {
    set(value: ThemePreference) {
      const preference = themePreference(value);
      apply(preference);
      try { win.localStorage.setItem(themePreferenceKey,preference); return true; } catch { return false; }
    },
    dispose() { win.removeEventListener("storage",onStorage); },
  };
}
