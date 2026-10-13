import { api, connectionVersion, getApiUrl } from './api';
import { contextManifest } from './projectContext';
import {
  encoded,
  HARD_MAX_BYTES,
  startBackgroundUpload,
  statUploadSource,
  uploadContextBlobResumable,
  type UploadSource,
} from './uploads';
export const CONTEXT_FILE_LIMIT = 10 * 1024 * 1024;
export const CONTEXT_PROJECT_LIMIT = 100 * 1024 * 1024;
export const CONFIRMED_PROJECT_LIMIT = 10 * 1024 * 1024 * 1024;

export interface ImportProjectFilesOptions {
  confirmedLarge?: boolean;
  onBackgroundStarted?: (path: string, source: UploadSource) => void;
}

/** Upload immutable bytes before publishing a conditional, versioned path. */
export async function importProjectFiles(
  slug: string,
  folder: string,
  sources: UploadSource[],
  options: ImportProjectFilesOptions = {},
): Promise<{ paths: string[]; warnings: string[]; largeFiles?: Array<{ source: UploadSource; size: number }> }> {
  const version = connectionVersion(),
    check = () => {
      if (version !== connectionVersion()) throw Error('Connection changed. Import stopped.');
    };
  if (
    folder.split('/').some(part => part === '.' || part === '..') ||
    folder.startsWith('/') ||
    folder.includes('\\')
  )
    throw Error('Invalid destination folder.');
  const manifest = await contextManifest(slug);
  check();
  const paths: string[] = [],
    warnings: string[] = [],
    largeFiles: Array<{ source: UploadSource; size: number }> = [];
  let size = Object.values(manifest.entries).reduce((sum, e) => sum + e.size, 0);
  const names = new Set(Object.keys(manifest.entries));
  for (const source of sources) {
    check();
    try {
      if (!source.name || /[\\/\x00-\x1f]/.test(source.name) || ['.', '..'].includes(source.name))
        throw Error('Invalid file name.');
      const stat = await statUploadSource(source);
      check();
      if (stat.size > HARD_MAX_BYTES) {
        throw Error('Too large to synchronize (2 GiB maximum per file).');
      }
      if (stat.size > CONTEXT_FILE_LIMIT && !options.confirmedLarge) {
        largeFiles.push({ source, size: stat.size });
        continue;
      }
      const dot = source.name.lastIndexOf('.'),
        stem = dot > 0 ? source.name.slice(0, dot) : source.name,
        ext = dot > 0 ? source.name.slice(dot) : '';
      const base = folder ? folder.replace(/\/$/, '') + '/' : '';
      let path = base + source.name,
        suffix = 2;
      while (names.has(path)) path = `${base}${stem} (${suffix++})${ext}`;
      const route = `/api/projects/${encodeURIComponent(slug)}/context`;

      if (stat.size > CONTEXT_FILE_LIMIT && options.confirmedLarge) {
        if (size + stat.size > CONFIRMED_PROJECT_LIMIT) {
          throw Error('Shared context would exceed its 10 GiB confirmed project limit.');
        }
        names.add(path);
        size += stat.size;
        const targetPath = path;
        startBackgroundUpload({
          source,
          destination: `context:${slug}`,
          totalBytes: stat.size,
          scope: `project:${slug}`,
          confirmedLarge: true,
          customRunner: async ({ signal, onProgress }) => {
            const uploaded = await uploadContextBlobResumable(slug, source, stat.size, stat.modified, {
              confirmedLarge: true,
              signal,
              onProgress,
            });
            const receipt = await api<{ conflict: boolean }>(`${route}/operations`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                id: crypto.randomUUID(),
                path: targetPath,
                base: null,
                hash: uploaded.hash,
                directory: false,
                delete: false,
                source: 'Orb file import',
                confirmed_large: true,
              }),
              signal,
            });
            if (receipt.conflict) {
              throw Error('Another file appeared at this path. The existing file was preserved; retry the import.');
            }
            window.dispatchEvent(new CustomEvent('orb:context-imported', { detail: { slug, paths: [targetPath] } }));
            return {
              source,
              path: targetPath,
              destination: `context:${slug}`,
              connection: connectionVersion(),
              endpoint: getApiUrl(),
              confirmedLarge: true,
            };
          },
          onComplete: () => {
            options.onBackgroundStarted?.(targetPath, source);
          },
        });
        paths.push(targetPath);
        continue;
      }

      const data = await encoded(source, CONTEXT_FILE_LIMIT);
      check();
      const bytes = Uint8Array.from(atob(data), c => c.charCodeAt(0));
      if (bytes.length > CONTEXT_FILE_LIMIT) throw Error('Too large to synchronize (10 MiB maximum per file).');
      if (size + bytes.length > CONTEXT_PROJECT_LIMIT)
        throw Error('Shared context would exceed its 100 MiB project limit.');
      const blob = await api<{ hash: string }>(`${route}/blobs`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/octet-stream' },
        body: bytes,
      });
      check();
      const receipt = await api<{ conflict: boolean }>(`${route}/operations`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          id: crypto.randomUUID(),
          path,
          base: null,
          hash: blob.hash,
          directory: false,
          delete: false,
          source: 'Orb file import',
        }),
      });
      check();
      if (receipt.conflict)
        throw Error('Another file appeared at this path. The existing file was preserved; retry the import.');
      size += bytes.length;
      names.add(path);
      paths.push(path);
    } catch (error) {
      check();
      warnings.push(`${source.name}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  if (paths.length) window.dispatchEvent(new CustomEvent('orb:context-imported', { detail: { slug, paths } }));
  return { paths, warnings, ...(largeFiles.length ? { largeFiles } : {}) };
}

