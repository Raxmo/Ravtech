import core.thread;
import core.time;
import std.math;
import utils;

/**
 * ScheduledEvent - Event with Fiber and execution time (in microseconds)
 */
struct ScheduledEvent
{
	Fiber fiber;
	long executeTimeUs;  // Microseconds since epoch (from TimeUtils)
	size_t index;  // Index in the event pool, used for cancellation
	EventScheduler* scheduler;  // Pointer to owning scheduler for cancellation
	
	/**
	 * Cancel this scheduled event (O(1) removal via swap-with-last)
	 */
	void cancel()
	{
		if (scheduler)
			scheduler.removeEvent(this.index);
	}
}

/**
 * EventScheduler - Timeline-based event system using Fibers with Ring Buffer
 * Events are scheduled with a delay or absolute time and executed deterministically
 * when their time arrives. Single-threaded, microsecond precision.
 * 
 * Architecture: Ring buffer pool with monotonic head pointer. Events are executed
 * when their scheduled time arrives; those scheduled during execution are processed
 * in subsequent `processReady()` iterations. Removal via swap-with-last.
 */
class EventScheduler
{
	private ScheduledEvent*[] events;  // Ring buffer pool of pointers (grows as needed)
	private size_t head;              // Monotonic position in ring (wraps via modulo)
	
	this()
	{
		events = [];
		head = 0;
	}
	
	/**
	 * Schedule an event to execute after a delay (microseconds)
	 * Returns a pointer to the event in the pool for optional cancellation
	 */
	ScheduledEvent* scheduleEvent(long delayUs, void delegate() action)
	{
		long executeTimeUs = TimeUtils.currTimeUs() + delayUs;
		return scheduleAtTime(executeTimeUs, action);
	}
	
	/**
	 * Schedule an event to execute at an absolute time (microseconds)
	 * Returns a pointer to the event in the pool for optional cancellation
	 */
	ScheduledEvent* scheduleAtTime(long executeTimeUs, void delegate() action)
	{
		// Create fiber that runs action directly
		Fiber fiber = new Fiber(() {
			action();
		});
		
		// Allocate event on heap
		ScheduledEvent* event = new ScheduledEvent(fiber, executeTimeUs, events.length, cast(EventScheduler*)this);
		
		// Add to pool
		events ~= event;
		return event;
	}
	
	/**
	 * Remove an event from the pool via swap-with-last (O(1) operation)
	 * The last event in pool is moved into the removed event's slot and
	 * its index updated. The removed event is destroyed.
	 */
	package void removeEvent(size_t index)
	{
		if (index >= events.length)
			return;
		
		ScheduledEvent* event = events[index];
		
		// Swap last event into this slot, update its index
		events[index] = events[$ - 1];
		events[index].index = index;
		events = events[0..$ - 1];
		destroy(event);
	}
	
	/**
	 * Process all ready events in the ring buffer
	 * Uses do-while loop with head position tracking to sweep pool exactly once,
	 * even as removal shrinks the array during iteration.
	 */
	void processReady()
	{
		if (events.length == 0)
			return; 
		
		long currentTimeUs = TimeUtils.currTimeUs();
		size_t startHead = head;
		
		// Sweep through pool starting at head, wrapping around exactly once
		do
		{
			ScheduledEvent* e = events[head];
			
			// Check if event is due
			if (e.executeTimeUs <= currentTimeUs)
			{
				// Execute the event
				e.fiber.call();
				
				// Remove completed event from pool by index
				removeEvent(e.index);
				
				// If pool is now empty, exit early
				if (events.length == 0)
				{
					head = 0;
					break;
				}
			}
			
			// Advance head after processing, wrapping if needed
			head = (head + 1) % events.length;
			
		} while (head != startHead && events.length > 0);
	}
	
	/**
	 * Process all ready events by repeatedly calling processReady()
	 * Runs while the pool has events.
	 * Handles event chaining: events scheduled during execution are processed
	 * as head sweeps through the pool.
	 */
	void processEvents()
	{
		while (events.length > 0)
		{
			processReady();
		}
	}
	
	/**
	 * Check if there are any pending events
	 */
	bool hasEvents()
	{
		return events.length > 0;
	}
	
	/**
	 * Get next event's execution time (microseconds)
	 */
	long nextEventTimeUs()
	{
		long nextTime = long.max;
		foreach (e; events)
		{
			if (e.executeTimeUs < nextTime)
				nextTime = e.executeTimeUs;
		}
		return nextTime;
	}
	
	/**
	 * Clear all events and reset head
	 */
	void clear()
	{
		foreach (e; events)
		{
			destroy(e);
		}
		events = [];
		head = 0;
	}
}