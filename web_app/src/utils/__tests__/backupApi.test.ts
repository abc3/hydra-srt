import { beforeEach, describe, expect, it, vi } from 'vitest';

const { authFetch } = vi.hoisted(() => ({ authFetch: vi.fn() }));

vi.mock('../auth', () => ({ authFetch }));

import { backupApi } from '../api';

describe('backupApi', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    authFetch.mockReset();
    vi.stubGlobal('URL', {
      createObjectURL: vi.fn(() => 'blob:backup'),
      revokeObjectURL: vi.fn(),
    });
    vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => undefined);
  });

  it('downloads an authenticated database backup with the server filename', async () => {
    authFetch.mockResolvedValue(
      new Response(new Blob(['sqlite']), {
        status: 200,
        headers: {
          'content-type': 'application/x-sqlite3',
          'content-disposition': 'attachment; filename="hydra-srt-2026.db"',
        },
      }),
    );

    await backupApi.downloadBackup();

    expect(authFetch).toHaveBeenCalledWith('/api/backup/full');
    expect(HTMLAnchorElement.prototype.click).toHaveBeenCalledOnce();
  });

  it('posts route backup JSON to the import endpoint', async () => {
    authFetch.mockResolvedValue(
      new Response(JSON.stringify({ message: 'Route backup imported successfully', routes_created: 1 }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      }),
    );

    const file = new File(
      [JSON.stringify({ backup_version: '1.0', routes: [] })],
      'hydra-srt-routes.json',
      { type: 'application/json' },
    );

    const result = await backupApi.importRoutes(file);

    expect(authFetch).toHaveBeenCalledWith('/api/backup/routes', {
      method: 'POST',
      body: file,
    });
    expect(result.routes_created).toBe(1);
  });

  it('reports download errors instead of showing a false success', async () => {
    authFetch.mockResolvedValue(
      new Response(JSON.stringify({ error: 'backup unavailable' }), {
        status: 500,
        headers: { 'content-type': 'application/json' },
      }),
    );

    await expect(backupApi.downloadBackup()).rejects.toThrow('backup unavailable');
    expect(HTMLAnchorElement.prototype.click).not.toHaveBeenCalled();
  });
});
