import type { ContentState } from '../lib/content';
import { DraftBanner, PreviewBanner } from './Banners';

export function Banners({ content, preview }: { content: ContentState; preview: boolean }) {
  return (
    <>
      {preview && <PreviewBanner />}
      <DraftBanner content={content} />
    </>
  );
}
