import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { RelativeTime } from './relative-time';
vi.mock('@/lib/now-tick', () => ({ useNow: () => Date.UTC(2026, 10, 2) }));
afterEach(cleanup);
describe('relative time month boundary', () => {
  it.each([[27, '3w ago'], [28, '4w ago'], [29, '4w ago'], [30, '1mo ago'], [59, '1mo ago'], [60, '2mo ago']])('formats %i days as %s', (days, expected) => {
    render(<RelativeTime date={new Date(Date.UTC(2026, 10, 2) - Number(days) * 86400000)} />);
    expect(screen.getByText(expected)).toBeInTheDocument();
  });
});
