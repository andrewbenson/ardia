import { useState } from "react";
import { Pressable, Text, View } from "react-native";
import { acceptEngineOffer, stayOnPage, useEngineOffers, type EngineOffer } from "../../lib/engines";
import { useTheme } from "../../lib/theme";
import { PRODUCT } from "../../lib/productName";
import { PanelCloseButton, Popover, PromptButton } from "../layout/controls";
import { Checkbox } from "../settings/controls";
import { PromptBody } from "./Prompts";
import { nativeToolbarAvailable } from "@ardia/settings";
import { NativePromptBody, PromptPopover } from "./NativePromptBody";

export function EngineOfferPrompt({ tabId, left, top }: { tabId: string; left: number; top: number }) {
  const offer = useEngineOffers((offers) => offers[tabId]);
  return offer ? <OfferPopover key={offer.site} tabId={tabId} offer={offer} left={left} top={top} /> : null;
}

function OfferPopover({ tabId, offer, left, top }: { tabId: string; offer: EngineOffer; left: number; top: number }) {
  const [remember, setRemember] = useState(false);
  const theme = useTheme();
  return (
    <PromptPopover width={320} top={top} left={left} modal={false}>
      {nativeToolbarAvailable() ? (
        <NativePromptBody
          spec={{
            icons: ["play.circle.fill", "safari"],
            title: `Play ${offer.host} in WebKit?`,
            message: `This site plays protected video, which Chromium in ${PRODUCT} can't. The page reloads in WebKit, which keeps its own sign-ins.`,
            details: offer.canRemember ? [{ kind: "checkbox", label: "Don't ask again for this site", value: remember }] : [],
            buttons: [{ id: "stay", title: "Stay on Page" }, { id: "webkit", title: "Open in WebKit", primary: true }],
          }}
          onButton={(id) => (id === "stay" ? stayOnPage(tabId, remember) : void acceptEngineOffer(tabId))}
          onToggle={setRemember}
          onClose={() => stayOnPage(tabId)}
        />
      ) : (
      <View>
        <PromptBody
          icons={["play.circle.fill", "safari"]}
          title={`Play ${offer.host} in WebKit?`}
          message={`This site plays protected video, which Chromium in ${PRODUCT} can't. The page reloads in WebKit, which keeps its own sign-ins.`}
          detail={
            offer.canRemember ? (
              <Pressable onPress={() => setRemember(!remember)} style={{ flexDirection: "row", alignItems: "flex-start", gap: 7 }}>
                <View style={{ marginTop: 1 }}>
                  <Checkbox value={remember} onChange={setRemember} />
                </View>
                <Text style={{ flex: 1, fontSize: 12, lineHeight: 16, color: theme.textPrimary }}>Don't ask again for this site</Text>
              </Pressable>
            ) : undefined
          }
        >
          <PromptButton title="Stay on Page" onPress={() => stayOnPage(tabId, remember)} />
          <PromptButton title="Open in WebKit" primary onPress={() => void acceptEngineOffer(tabId)} />
        </PromptBody>
        <PanelCloseButton onPress={() => stayOnPage(tabId)} />
      </View>
      )}
    </PromptPopover>
  );
}
