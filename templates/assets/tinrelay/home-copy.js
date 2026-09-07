(() => {
  const label = "COPY PROMPT";
  const quote = document.querySelector('body[data-page="home"] main > blockquote');
  const prompt = quote?.querySelector("p");
  if (!quote || !prompt) return;

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
})();
