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
}

/**
 * EventScheduler - Timeline-based event system using Fibers with Ring Buffer
 * Events are scheduled with a delay or absolute time and executed deterministically
 * when their time arrives. Single-threaded, microsecond precision.
 * 
 * Architecture: Ring buffer pool with monotonic head pointer. Events are executed
 * when their scheduled time arrives; those scheduled during execution are processed
 * in subsequent `processNext()` iterations. Removal via swap-with-last.
 */
class EventScheduler
{
	private ScheduledEvent[] events;  // Ring buffer pool (grows as needed)
	private size_t eventCount;       // Actual number of events in pool
	private size_t head;             // Monotonic position in ring (wraps via modulo)
	
	this()
	{
		events = [];
		eventCount = 0;
		head = 0;
	}
	
	/**
	 * Schedule an event to execute after a delay (microseconds)
	 * Returns a reference to the event in the pool for optional cancellation
	 */
	ref ScheduledEvent scheduleEvent(long delayUs, void delegate() action)
	{
		long executeTimeUs = TimeUtils.currTimeUs() + delayUs;
		return scheduleAtTime(executeTimeUs, action);
	}
	
	/**
	 * Schedule an event to execute at an absolute time (microseconds)
	 * Returns a reference to the event in the pool for optional cancellation
	 */
	ref ScheduledEvent scheduleAtTime(long executeTimeUs, void delegate() action)
	{
		// Create fiber that runs action directly (no internal waiting)
		// Scheduler controls all timing via processNext()
		Fiber fiber = new Fiber(() {
			action();
		});
		
		// Grow pool if needed (infrequent after startup)
		if (eventCount >= events.length)
		{
			events.length = events.length == 0 ? 32 : events.length * 2;
		}
		
		size_t idx = eventCount;
		events[idx] = ScheduledEvent(fiber, executeTimeUs, idx);
		eventCount++;
		return events[idx];
	}
	
	/**
	 * Cancel a scheduled event by reference (O(1) swap-with-last removal)
	 * The last event in pool is moved into the cancelled event's slot and
	 * its index updated. An event that reschedules itself executes immediately
	 * and swaps itself with the newly scheduled copy, naturally deferring itself
	 * until the next sweep through the pool.
	 */
	void cancel(ref ScheduledEvent event)
	{
		size_t idx = event.index;
		if (idx < eventCount && &events[idx] is &event)
		{
			// Swap last event into this slot, update its index
			events[idx] = events[eventCount - 1];
			events[idx].index = idx;
			eventCount--;
		}
	}
	
	/**
	 * Process the next ready event in the ring buffer
	 * Advances head monotonically; returns true if an event was executed,
	 * false if no more events are ready at current time.
	 * 
	 * Events scheduled during execution are added to the pool and will be
	 * encountered as head continues sweeping. Terminated fibers are removed
	 * immediately via swap-with-last.
	 */
	bool processNext()
	{
		if (eventCount == 0)
			return false;
		
		long currentTimeUs = TimeUtils.currTimeUs();
		
		// Sweep through pool looking for ready events
		for (size_t attempts = 0; attempts < eventCount; attempts++)
		{
			size_t pos = head % eventCount;
			ref ScheduledEvent e = events[pos];
			head++;
			
			// Remove terminated fibers immediately
			if (e.fiber.state == Fiber.State.TERM)
			{
				// Swap last event into this position, update its index
				events[pos] = events[eventCount - 1];
				events[pos].index = pos;
				eventCount--;
				// Don't increment head past removed slot; check it again on next iteration
				head--;
				continue;
			}
			
			// Check if ready
			if (e.executeTimeUs <= currentTimeUs)
			{
				e.fiber.call();
				return true;  // Processed one event
			}
			
			// Event not ready yet; no point checking further (not in time order)
			return false;
		}
		
		return false;
	}
	
	/**
	 * Process all ready events by repeatedly calling processNext()
	 * Runs until no more events are ready at current time.
	 * Handles event chaining: events scheduled during execution are processed
	 * as head sweeps through the pool.
	 */
	void processEvents()
	{
		while (processNext())
		{
			// Keep processing ready events
		}
	}
	
	/**
	 * Check if there are any pending events
	 * Pool contains only live events (terminated fibers removed immediately)
	 */
	bool hasEvents()
	{
		return eventCount > 0;
	}
	
	/**
	 * Get next event's execution time (microseconds)
	 */
	long nextEventTimeUs()
	{
		long nextTime = long.max;
		foreach (e; events[0..eventCount])
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
		events = [];
		eventCount = 0;
		head = 0;
	}
}

unittest
{
	import core.thread;
	import std.stdio;
	
	// Test: Event Chaining (single)
	{
		EventScheduler scheduler = new EventScheduler();
		int[] executionOrder;
		
		long nowUs = TimeUtils.currTimeUs();
		long baseTimeUs = nowUs;
		
		// Event A schedules Event B, which schedules Event C
		scheduler.scheduleAtTime(baseTimeUs + 10_000, () {
			executionOrder ~= 1;  // A
			scheduler.scheduleAtTime(TimeUtils.currTimeUs() + 5_000, () {
				executionOrder ~= 2;  // B
				scheduler.scheduleAtTime(TimeUtils.currTimeUs() + 5_000, () {
					executionOrder ~= 3;  // C
				});
			});
		});
		
		// Poll until all events complete
		long pollDeadlineUs = baseTimeUs + 100_000;  // 100ms timeout
		while (scheduler.hasEvents() && TimeUtils.currTimeUs() < pollDeadlineUs)
		{
			scheduler.processEvents();
		}
		
		assert(executionOrder.length == 3, "Not all chained events executed");
		assert(executionOrder[0] == 1, "Event A did not execute first");
		assert(executionOrder[1] == 2, "Event B did not execute second");
		assert(executionOrder[2] == 3, "Event C did not execute third");
		writeln("  Event chaining (A→B→C): PASS");
	}
	
	// Test: Event Self-Reschedule (event reschedules itself by canceling and scheduling new)
	{
		EventScheduler scheduler = new EventScheduler();
		int[] executionTimes;
		
		long baseTimeUs = TimeUtils.currTimeUs();
		
		// Event that reschedules itself multiple times
		ref ScheduledEvent event = scheduler.scheduleAtTime(baseTimeUs + 5_000, () {
			executionTimes ~= 1;
		});
		
		// Simulate rescheduling: cancel current, schedule new at deferred time
		scheduler.scheduleAtTime(baseTimeUs + 2_000, () {
			// Cancel the original event
			scheduler.cancel(event);
			// Schedule a new event (simulating reschedule)
			scheduler.scheduleAtTime(TimeUtils.currTimeUs() + 3_000, () {
				executionTimes ~= 2;
			});
		});
		
		long pollDeadlineUs = baseTimeUs + 100_000;
		while (scheduler.hasEvents() && TimeUtils.currTimeUs() < pollDeadlineUs)
		{
			scheduler.processEvents();
		}
		
		assert(executionTimes.length == 1, "Reschedule chain failed");
		assert(executionTimes[0] == 2, "Rescheduled event did not execute");
		writeln("  Event reschedule: PASS");
	}
	
	// Test: Cancellation During Chain (cancel B while A is executing)
	{
		EventScheduler scheduler = new EventScheduler();
		int[] executionOrder;
		
		long nowUs = TimeUtils.currTimeUs();
		long baseTimeUs = nowUs;
		
		ref ScheduledEvent eventB = scheduler.scheduleAtTime(baseTimeUs + 5_000, () {
			executionOrder ~= 2;  // Should NOT execute
		});
		
		scheduler.scheduleAtTime(baseTimeUs + 2_500, () {
			executionOrder ~= 1;  // A
			scheduler.cancel(eventB);  // Cancel B during A's execution
		});
		
		long pollDeadlineUs = baseTimeUs + 100_000;
		while (scheduler.hasEvents() && TimeUtils.currTimeUs() < pollDeadlineUs)
		{
			scheduler.processEvents();
		}
		
		assert(executionOrder.length == 1, "Cancelled event still executed");
		assert(executionOrder[0] == 1, "Event A did not execute");
		writeln("  Cancellation during chain: PASS");
	}
	
	// Test: Basic Event Scheduling with Timing Verification (1 second)
	{
		EventScheduler scheduler = new EventScheduler();
		bool executed = false;
		long actualExecutionTimeUs;
		
		long nowUs = TimeUtils.currTimeUs();
		long scheduledTimeUs = nowUs + 1_000_000;  // 1 second in microseconds
		
		ref ScheduledEvent event = scheduler.scheduleAtTime(scheduledTimeUs, () {
			executed = true;
			actualExecutionTimeUs = TimeUtils.currTimeUs();
		});
		
		// Event should not be executed yet
		scheduler.processEvents();
		assert(!executed, "Event executed too early");
		
		// Poll processEvents until event executes
		while (!executed && TimeUtils.currTimeUs() < scheduledTimeUs + 100_000)  // 100ms timeout
		{
			scheduler.processEvents();
		}
		
		assert(executed, "Event did not execute");
		
		// Calculate timing accuracy (in microseconds)
		long errorUs = actualExecutionTimeUs - scheduledTimeUs;
		double nsPerTick = TimeUtils.getNanosecondsPerTick();
		long tps = TimeUtils.getTicksPerSecond();
		
		writeln("  Platform Resolution:");
		writeln("    ticksPerSecond: ", tps);
		writeln("    nanoseconds per tick: ", nsPerTick);
		writeln("  Scheduled: ", scheduledTimeUs, " µs");
		writeln("  Executed:  ", actualExecutionTimeUs, " µs");
		writeln("  Error:     ", errorUs, " µs (", errorUs / 1000, " ms)");
		assert(errorUs >= 0, "Event executed before scheduled time");
		assert(errorUs < 100_000, "Timing error too large (>100ms)");
	}
	
	// Test: Event Cancellation
	{
		EventScheduler scheduler = new EventScheduler();
		bool executed = false;
		
		long nowUs = TimeUtils.currTimeUs();
		long execTimeUs = nowUs + 200_000;  // 200ms in microseconds
		
		ref ScheduledEvent event = scheduler.scheduleAtTime(execTimeUs, () {
			executed = true;
		});
		
		// Cancel before execution
		scheduler.cancel(event);
		
		// Wait past execution time
		Thread.sleep(250.msecs);
		scheduler.processEvents();
		assert(!executed, "Canceled event still executed");
	}
	
	// Test: Multiple Events
	{
		EventScheduler scheduler = new EventScheduler();
		int count = 0;
		
		long nowUs = TimeUtils.currTimeUs();
		
		scheduler.scheduleAtTime(nowUs + 100_000, () { count++; });  // 100ms
		scheduler.scheduleAtTime(nowUs + 50_000, () { count++; });   // 50ms
		scheduler.scheduleAtTime(nowUs + 150_000, () { count++; });  // 150ms
		
		Thread.sleep(200.msecs);
		scheduler.processEvents();
		
		assert(count == 3, "Not all events executed");
	}
	
	// Test: hasEvents() Tracking
	{
		EventScheduler scheduler = new EventScheduler();
		assert(!scheduler.hasEvents(), "New scheduler should have no events");
		
		long nowUs = TimeUtils.currTimeUs();
		ref ScheduledEvent event = scheduler.scheduleAtTime(nowUs + 100_000, () {});
		
		assert(scheduler.hasEvents(), "Scheduler should have events after scheduling");
		
		scheduler.cancel(event);
		assert(!scheduler.hasEvents(), "Scheduler should have no events after cancellation");
	}
	
	// Test: Timing Variance with 5ms intervals (1000 events)
	{
		EventScheduler scheduler = new EventScheduler();
		long[] executionErrors;  // Timing errors in microseconds
		
		long baseTimeUs = TimeUtils.currTimeUs();
		long intervalUs = 5_000;  // 5 millisecond interval
		int eventCount = 1000;
		
		// Schedule 100 events at 50µs intervals
		for (int i = 0; i < eventCount; i++)
		{
			long scheduleTimeUs = baseTimeUs + (i * intervalUs);
			scheduler.scheduleAtTime(scheduleTimeUs, () {
				long actualTimeUs = TimeUtils.currTimeUs();
				long scheduledTimeUs = baseTimeUs + (cast(int)executionErrors.length * intervalUs);
				long errorUs = actualTimeUs - scheduledTimeUs;
				executionErrors ~= errorUs;
			});
		}
		
		// Process all events by polling
		long pollDeadlineUs = baseTimeUs + (eventCount * intervalUs) + 10_000;  // 10ms buffer
		while (scheduler.hasEvents() && TimeUtils.currTimeUs() < pollDeadlineUs)
		{
			scheduler.processEvents();
		}
		
		// Calculate statistics
		if (executionErrors.length > 0)
		{
			long minErrorUs = executionErrors[0];
			long maxErrorUs = executionErrors[0];
			long sumErrorUs = 0;
			long sumSquaredErrorUs = 0;
			
			foreach (err; executionErrors)
			{
				if (err < minErrorUs) minErrorUs = err;
				if (err > maxErrorUs) maxErrorUs = err;
				sumErrorUs += err;
				sumSquaredErrorUs += err * err;
			}
			
			long meanErrorUs = sumErrorUs / cast(long)executionErrors.length;
			long varianceUs = sumSquaredErrorUs / cast(long)executionErrors.length - (meanErrorUs * meanErrorUs);
			double stddevUs = (varianceUs >= 0) ? sqrt(cast(double)varianceUs) : 0.0;
			
			writeln("\n  Timing Variance Test (5ms intervals, ", eventCount, " events):");
			
			// Histogram of errors to show distribution
			long[] errorBuckets = [0, 0, 0, 0, 0];  // 0-50, 50-100, 100-200, 200-500, 500+
			foreach (err; executionErrors)
			{
				if (err <= 50) errorBuckets[0]++;
				else if (err <= 100) errorBuckets[1]++;
				else if (err <= 200) errorBuckets[2]++;
				else if (err <= 500) errorBuckets[3]++;
				else errorBuckets[4]++;
			}
			writeln("    Error distribution:");
			writeln("      0-50µs:   ", errorBuckets[0], " events");
			writeln("      50-100µs: ", errorBuckets[1], " events");
			writeln("      100-200µs:", errorBuckets[2], " events");
			writeln("      200-500µs:", errorBuckets[3], " events");
			writeln("      500µs+:   ", errorBuckets[4], " events");
			writeln("    Events executed: ", executionErrors.length);
			writeln("    Min error:  ", minErrorUs, " µs");
			writeln("    Max error:  ", maxErrorUs, " µs");
			writeln("    Mean error: ", meanErrorUs, " µs");
			writeln("    Stddev:     ", stddevUs, " µs");
			writeln("    Range:      ", (maxErrorUs - minErrorUs), " µs");
		}
	}
}