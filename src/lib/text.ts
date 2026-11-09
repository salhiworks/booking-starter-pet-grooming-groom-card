/** The same text without the asterisks (titles, labels). */
export function plainText(text: string): string {
  return text.replace(/\*([^*]+)\*/g, '$1').replace(/\*/g, '');
}
