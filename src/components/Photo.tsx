import type { SiteImage } from '@profitstudio/booking-engine';
import { PHOTO_VARIANTS } from '../content/photoVariants';

interface PhotoProps {
  image: SiteImage;
  /** Must match the frame's width in the layout. */
  sizes: string;
  /** The first-screen photo: eager, high priority (it is also preloaded in index.html). */
  priority?: boolean;
  className?: string;
  /**
   * Art direction for small screens (the site's own default only): another crop of the same
   * moment, by its key in PHOTO_VARIANTS, used below `media`.
   */
  small?: { key: string; media: string; sizes: string };
}

/**
 * A photo in a fixed-ratio frame (the frame's CSS sets aspect-ratio and
 * object-fit: cover, so an owner's replacement never breaks the layout).
 * The site's own defaults render as <picture> with AVIF/WebP variants; the
 * owner's uploads arrive resized and render as one <img>.
 */
export function Photo({ image, sizes, priority = false, className, small }: PhotoProps) {
  const variants = PHOTO_VARIANTS[image.src];
  const smallVariants = small ? PHOTO_VARIANTS[small.key] : undefined;
  const width = variants?.width ?? image.width ?? 1200;
  const height = variants?.height ?? image.height ?? 1500;
  const img = (
    <img
      src={image.src}
      alt={image.alt}
      width={width}
      height={height}
      loading={priority ? 'eager' : 'lazy'}
      decoding="async"
      fetchPriority={priority ? 'high' : undefined}
    />
  );
  return (
    <div className={`frame ${className ?? ''}`}>
      {variants ? (
        <picture>
          {small && smallVariants && (
            <>
              <source media={small.media} type="image/avif" srcSet={smallVariants.avif} sizes={small.sizes} />
              <source media={small.media} type="image/webp" srcSet={smallVariants.webp} sizes={small.sizes} />
            </>
          )}
          <source type="image/avif" srcSet={variants.avif} sizes={sizes} />
          <source type="image/webp" srcSet={variants.webp} sizes={sizes} />
          {img}
        </picture>
      ) : (
        img
      )}
    </div>
  );
}
