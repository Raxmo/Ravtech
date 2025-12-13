import core.thread;
import core.time;

/**
 * ScheduledEvent - Event with Fiber and execution time
 */
private struct ScheduledEvent
{
	Fiber fiber;
	MonoTime executeTime;
	size_t index;  // Index in the event pool, used for cancellation
}

/**
 * EventScheduler - Timeline-based event system using Fibers
 * Events are scheduled with a delay or absolute time and executed deterministically
 * when their time arrives. Single-threaded, nanosecond precision.
 */
class EventScheduler
{
	private ScheduledEvent[] events;
	
	this()
	{
		events = [];
	}
	
	/**
	 * Schedule an event to execute after a delay
	 * Returns a reference to the event in the pool for optional cancellation
	 */
	ref ScheduledEvent scheduleEvent(Duration delay, void delegate() action)
	{
		MonoTime executeTime = MonoTime.currTime() + delay;
		return scheduleAtTime(executeTime, action);
	}
	
	/**
	 * Schedule an event to execute at an absolute time
	 * Returns a reference to the event in the pool for optional cancellation
	 */
	ref ScheduledEvent scheduleAtTime(MonoTime executeTime, void delegate() action)
	{
		// Create fiber that waits until executeTime, then runs action
		Fiber fiber = new Fiber(() {
			while (MonoTime.currTime() < executeTime)
			{
				Fiber.yield();
			}
			action();
		});
		
		size_t idx = events.length;
		events ~= ScheduledEvent(fiber, executeTime, idx);
		return events[$ - 1];
	}
	
	/**
	 * Cancel a scheduled event by reference
	 * Removes the event immediately from the pool using swap-with-last
	 * The swapped-in event's index field is updated to maintain reference validity
	 */
	void cancel(ref ScheduledEvent event)
	{
		size_t idx = event.index;
		if (idx < events.length && &events[idx] is &event)
		{
			events[idx] = events[$ - 1];
			events[idx].index = idx;  // Swapped event inherits the index
			events = events[0..$ - 1];
		}
	}
	
	/**
	 * Process all events due at current time
	 */
	void processEvents()
	{
		MonoTime currentTime = MonoTime.currTime();
		
		// Remove finished fibers using swap-with-last
		size_t i = 0;
		while (i < events.length)
		{
			if (events[i].fiber.state == Fiber.State.TERM)
			{
				events[i] = events[$ - 1];
				events = events[0..$ - 1];
			}
			else
			{
				i++;
			}
		}
		
		// Resume fibers that are ready
		foreach (ref e; events)
		{
			if (e.executeTime <= currentTime && e.fiber.state != Fiber.State.TERM)
			{
				e.fiber.call();
			}
		}
	}
	
	/**
	 * Check if there are any pending non-terminated events
	 */
	bool hasEvents()
	{
		foreach (e; events)
		{
			if (e.fiber.state != Fiber.State.TERM)
				return true;
		}
		return false;
	}
	
	/**
	 * Get next event's execution time
	 */
	MonoTime nextEventTime()
	{
		MonoTime nextTime = MonoTime.max;
		foreach (e; events)
		{
			if (e.fiber.state != Fiber.State.TERM && e.executeTime < nextTime)
				nextTime = e.executeTime;
		}
		return nextTime;
	}
	
	/**
	 * Clear all events
	 */
	void clear()
	{
		events = [];
	}
}