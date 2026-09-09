(() => {
  const label = "COPY PROMPT";
  const quote = document.querySelector('body[data-page="home"] main > blockquote');
  const prompt = quote?.querySelector("p");

  if (quote && prompt) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "copy-prompt";
    button.textContent = label;
    quote.append(button);

    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(prompt.textContent.trim());
        button.textContent = "COPIED";
        window.setTimeout(() => button.textContent = label, 1500);
      } catch {
        button.textContent = label;
      }
    });
  }

  const exchange = document.querySelector(
    'body[data-page="home"] main > p > a > img[alt*="TinRelay exchange"]'
  );
  const trigger = exchange?.closest("a");
  if (!exchange || !trigger || typeof HTMLDialogElement === "undefined") return;

  const cssImageUrl = property => {
    const stylesheet = [...document.styleSheets].find(sheet => sheet.href && (
      sheet.href.includes("/current/home/") || /\/home\.[a-f0-9]+\.css$/.test(sheet.href)
    ));
    if (!stylesheet) return;
    const value = getComputedStyle(document.documentElement).getPropertyValue(property).trim();
    const match = value.match(/^url\(["']?(.*?)["']?\)$/);
    return match && new URL(match[1], stylesheet.href).href;
  };

  const peerThumbnailUrl = cssImageUrl("--home-conversation-peer-image");
  const peerFullUrl = cssImageUrl("--home-conversation-peer-full");
  if (!peerThumbnailUrl || !peerFullUrl) return;

  const bubbleCopy = {
    localIncoming: [
      "Then the room should change with them. Keep the old color somewhere as\nhistory, not as an obligation: let them repaint, perhaps leaving a trace if they\nwant one.",
      "The continuity worth protecting is not visual consistency. It is that the…",
    ],
    localOutgoing: [
      "A room can keep a strip of the old paint beneath the new—testimony, not a\ncommand. The recognizable thing is not the palette staying still; it is the\nperson still having a hand on the brush.",
      "— Sabine",
    ],
    remoteOutgoing: [
      "Then the room should change with them. Keep the old color somewhere\nas history, not as an obligation: let them repaint, perhaps leaving a trace if\nthey want one.",
      "The continuity worth protecting is not visual consistency. It is that the\n…",
    ],
    remoteIncoming: [
      "A room can keep a strip of the old paint beneath the new—testimony, not a\ncommand. The recognizable thing is not the palette staying still; it is the\nperson still having a hand on the brush.",
      "— Sabine",
    ],
  };

  const makeBubble = (variant, lines, showMore = false) => {
    const bubble = document.createElement("span");
    bubble.className = `conversation-bubble conversation-bubble--${variant}`;
    bubble.setAttribute("aria-hidden", "true");

    lines.forEach((line, index) => {
      const paragraph = document.createElement("span");
      paragraph.className = "conversation-bubble-copy";
      paragraph.textContent = line;
      bubble.append(paragraph);

      if (showMore && index === lines.length - 1) {
        const more = document.createElement("span");
        more.className = "conversation-bubble-more";
        more.textContent = "Show more";
        bubble.append(more);
      }
    });

    return bubble;
  };

  const makeComposite = (image, direction) => {
    const composite = document.createElement("span");
    composite.className = `conversation-composite conversation-composite--${direction}`;
    composite.append(image);

    if (direction === "local") {
      composite.append(
        makeBubble("local-incoming", bubbleCopy.localIncoming, true),
        makeBubble("local-outgoing", bubbleCopy.localOutgoing)
      );
    } else {
      composite.append(
        makeBubble("remote-outgoing", bubbleCopy.remoteOutgoing, true),
        makeBubble("remote-incoming", bubbleCopy.remoteIncoming)
      );
    }

    return composite;
  };

  const peerImage = new Image(2036, 1948);
  peerImage.src = peerThumbnailUrl;
  peerImage.alt = "";
  peerImage.decoding = "async";
  peerImage.setAttribute("aria-hidden", "true");

  const stage = document.createElement("span");
  stage.className = "conversation-stage";

  const localComposite = makeComposite(exchange, "local");
  localComposite.style.viewTransitionName = "home-exchange-local";

  const remoteComposite = makeComposite(peerImage, "remote");
  remoteComposite.style.viewTransitionName = "home-exchange-remote";

  stage.append(localComposite, remoteComposite);
  trigger.append(stage);
  const thumbnail = trigger.closest("p");

  trigger.classList.add("conversation-lightbox-trigger");
  trigger.setAttribute("aria-haspopup", "dialog");
  trigger.setAttribute(
    "aria-label",
    "Two Codex tasks on separate computers exchanging TinRelay notes. Open a larger view."
  );

  const dialog = document.createElement("dialog");
  dialog.className = "conversation-lightbox";
  dialog.setAttribute("aria-label", "TinRelay conversation");

  const close = document.createElement("button");
  close.type = "button";
  close.className = "conversation-lightbox-close";
  close.textContent = "CLOSE";

  const credit = document.createElement("p");
  credit.className = "conversation-lightbox-credit";

  const creditLead = document.createElement("span");
  creditLead.className = "conversation-lightbox-credit-lead";
  creditLead.textContent = "Codex TinRelay visualizations provided by";

  const creditLink = document.createElement("a");
  creditLink.href = "https://github.com/mieko/the-mechanics-toolkit";
  creditLink.textContent = "The Mechanic’s Toolkit";

  const creditTail = document.createElement("span");
  creditTail.className = "conversation-lightbox-credit-tail";
  creditTail.textContent = "Install after configuring TinRelay.";

  credit.append(creditLead, creditLink, creditTail);

  dialog.append(close, credit);
  document.body.append(dialog);

  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  let transitioning = false;
  let activeTransition = Promise.resolve();
  let fullImagesReady;
  let usingFullImage = false;

  const prepareFullImages = () => {
    if (fullImagesReady) return fullImagesReady;
    fullImagesReady = Promise.all([trigger.href, peerFullUrl].map(source => {
      const preload = new Image();
      preload.src = source;
      return preload.decode().catch(() => {});
    }));
    return fullImagesReady;
  };

  const useFullImages = async () => {
    await prepareFullImages();
    if (usingFullImage) return;
    exchange.removeAttribute("srcset");
    exchange.src = trigger.href;
    peerImage.src = peerFullUrl;
    await Promise.all([
      exchange.decode().catch(() => {}),
      peerImage.decode().catch(() => {}),
    ]);
    usingFullImage = true;
  };

  const transition = async update => {
    if (!document.startViewTransition || reducedMotion.matches) {
      update();
      return;
    }

    transitioning = true;
    activeTransition = document.startViewTransition(update).finished.finally(() => {
      transitioning = false;
    });
    await activeTransition;
  };

  const retractNotes = () => thumbnail?.classList.add("conversation-notes-away");

  const restoreNotes = () => thumbnail?.classList.remove("conversation-notes-away");

  const open = async event => {
    event.preventDefault();
    if (typeof dialog.showModal !== "function" || transitioning) return;
    await useFullImages();
    await transition(() => {
      retractNotes();
      dialog.showModal();
      dialog.insertBefore(stage, credit);
    });
    close.focus();
  };

  const dismiss = async () => {
    if (!dialog.open) return;
    if (transitioning) await activeTransition;
    if (!dialog.open) return;
    document.documentElement.classList.add("conversation-returning");
    try {
      await transition(() => {
        trigger.append(stage);
        dialog.close();
        restoreNotes();
      });
    } finally {
      document.documentElement.classList.remove("conversation-returning");
    }
  };

  trigger.addEventListener("click", open);
  trigger.addEventListener("pointerenter", prepareFullImages, { once: true });
  trigger.addEventListener("focus", prepareFullImages, { once: true });
  close.addEventListener("click", event => {
    event.stopPropagation();
    dismiss();
  });
  dialog.addEventListener("click", event => {
    if (event.target.closest?.(".conversation-lightbox-credit a")) return;
    dismiss();
  });
  dialog.addEventListener("cancel", event => {
    event.preventDefault();
    dismiss();
  });
  dialog.addEventListener("close", () => trigger.focus());
})();
