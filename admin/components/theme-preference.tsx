"use client";

import {createContext, useContext, useEffect, useRef, useState, type ReactNode} from "react";
import {bindThemePreference, type ThemePreference} from "@/lib/theme-preference";

type Appearance = {preference:ThemePreference; ready:boolean; persisted:boolean; change:(value:ThemePreference)=>void};
const AppearanceContext = createContext<Appearance|null>(null);

export function ThemePreferenceProvider({children}:{children:ReactNode}) {
  const [preference,setPreference] = useState<ThemePreference>("system");
  const [ready,setReady] = useState(false);
  const [persisted,setPersisted] = useState(true);
  const controller = useRef<ReturnType<typeof bindThemePreference>|null>(null);
  useEffect(()=>{
    const binding=bindThemePreference(window,document.documentElement,setPreference);
    controller.current=binding;
    setReady(true);
    return ()=>{binding.dispose();controller.current=null;};
  },[]);
  return <AppearanceContext.Provider value={{preference,ready,persisted,change:value=>{
    if(controller.current)setPersisted(controller.current.set(value));
  }}}>{children}</AppearanceContext.Provider>;
}

export function ThemePreferenceControl() {
  const appearance=useContext(AppearanceContext);
  if(!appearance)return null; // Server rollout off: no selector or persistence.
  return <div className="theme-preference-control">
    <label htmlFor="console-appearance">Appearance</label>
    <select id="console-appearance" className="select" disabled={!appearance.ready} value={appearance.preference}
      aria-describedby="console-appearance-hint" onChange={event=>appearance.change(event.target.value as ThemePreference)}>
      <option value="system">Use device setting</option><option value="light">Light</option><option value="dark">Dark</option>
    </select>
    <p id="console-appearance-hint" role="status">{appearance.persisted?"Appearance only. No account data is stored.":"Applied in this tab. Your browser could not save the preference."}</p>
  </div>;
}
