import { useState } from 'react';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it } from 'vitest';
import { EnvVarsEditor, envRowsToMap, toEnvRows } from './env-vars-editor';
afterEach(cleanup);
describe('environment key editing', () => {
  it('preserves own property names and last duplicate values through JSON', () => {
    const rows = toEnvRows(JSON.parse('{"__proto__":"value","constructor":"other","NORMAL":"old"}'));
    rows.push({ ...rows[2], id: 'duplicate', key: ' NORMAL ', value: 'new' });
    const saved = JSON.parse(JSON.stringify(envRowsToMap(rows)));
    expect(Object.hasOwn(saved, '__proto__')).toBe(true);
    expect(saved.__proto__).toBe('value'); expect(saved.constructor).toBe('other'); expect(saved.NORMAL).toBe('new');
  });
  it('hides a visible value when its key becomes sensitive', () => {
    function Fixture() {
      const [rows, setRows] = useState(toEnvRows({ NORMAL: 'fixture-value' }));
      return <EnvVarsEditor rows={rows} onChange={setRows} />;
    }
    render(<Fixture />);
    const value = screen.getByPlaceholderText('value'); expect(value).toHaveAttribute('type', 'text');
    fireEvent.change(screen.getByPlaceholderText('KEY'), { target: { value: 'API_TOKEN' } });
    expect(value).toHaveAttribute('type', 'password'); expect(value).toHaveValue('fixture-value');
  });
  it('does not reveal an encrypted value when renamed to an ordinary key', () => {
    function Fixture() {
      const [rows, setRows] = useState(toEnvRows({ API_TOKEN: 'fixture-value' }));
      return <EnvVarsEditor rows={rows} onChange={setRows} />;
    }
    render(<Fixture />);
    fireEvent.change(screen.getByPlaceholderText('KEY'), { target: { value: 'NORMAL' } });
    expect(screen.getByPlaceholderText('value')).toHaveAttribute('type', 'password');
  });
});
