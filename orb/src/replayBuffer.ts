import type {StreamEvent} from './stream';
import {estimateCacheBytes} from './pageCache';
/** Paging may replay recent live events until the durable log catches up.
 * Never retain an unbounded stream of cumulative text snapshots. */
export class ReplayBuffer {
  events: StreamEvent[] = [];
  available = true;
  private bytes = 0;
  constructor(private budget = 8 * 1024 * 1024, private limit = 4096) {}
  push(events: StreamEvent[]) {
    if (!this.available) return;
    for (const event of events) {
      this.bytes += estimateCacheBytes(event);
      if (this.bytes > this.budget || this.events.length >= this.limit) {
        this.events = []; this.bytes = 0; this.available = false; return;
      }
      this.events.push(event);
    }
  }
  reset() { this.events = []; this.bytes = 0; this.available = true; }
}
