export type Article = {
  id: string;
  title: string;
  topic: string;
  body: string;
};

export const ARTICLES: Article[] = [
  {
    id: "water",
    title: "Drinking water when the tap stops",
    topic: "Water",
    body: "Boil clear water for one minute, then let it cool before drinking. If the water is cloudy, let it settle and pour off the clear part first. Store cooled water in clean, covered containers. A local note is not a treatment plant: when in doubt, do not drink it.",
  },
  {
    id: "aid",
    title: "Bleeding: first steps",
    topic: "First aid",
    body: "Press a clean cloth firmly on the wound and keep pressing. If blood soaks through, add another cloth. Do not remove the first one. Raise the injured part if you can do that without making the pain much worse. This is an aid, not a clinician. Get a person with medical training as soon as you can.",
  },
  {
    id: "power",
    title: "Keep the node running",
    topic: "Power",
    body: "The node is a laptop. Dim the screen, close unused work, and prefer the battery you already charged. A power bank helps. The web console, the small model, and the saved library stay available with the internet unplugged. New models and new archives do not.",
  },
  {
    id: "radio",
    title: "What each radio is for",
    topic: "Radio",
    body: "The Wi-Fi named Nodo carries this console. Phones nearby open http://10.41.0.1. Meshtastic needs a LoRa board for each person and only carries short text. Bitchat is a phone app over Bluetooth, with no extra hardware and a short range. FM listening needs a separate USB receiver. None of these is a replacement for the public telephone network.",
  },
];

export function searchLibrary(query: string): Article[] {
  const terms = query
    .toLowerCase()
    .split(/\s+/)
    .map((term) => term.trim())
    .filter((term) => term.length > 2);
  if (terms.length === 0) return ARTICLES;
  return ARTICLES.filter((article) => {
    const haystack = `${article.title} ${article.topic} ${article.body}`.toLowerCase();
    return terms.some((term) => haystack.includes(term));
  });
}
