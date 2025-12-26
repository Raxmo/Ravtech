import core.thread;
import core.time;
import std.stdio;
import std.algorithm;
import utils;

/**
 * ITrigger - Type-erased trigger interface
 * 
 * All triggers implement this interface to allow type-agnostic scheduling.
 * The scheduler works entirely with ITrigger references.
 */
interface ITrigger
{
	/// Execute the trigger, notifying its linked event with stored payload
	void notify();
}



/**
 * Event - Simple stateful event with typed payload and flat listener pool
 * 
 * Events are notification delivery: fire() calls all listeners.
 * Propagation (hierarchical, conditional, etc.) is caller responsibility.
 * The event object itself is the identity; no string name needed.
 * 
 * T: Payload type
 */
class Event(T)
{
	alias ListenerDelegate = void delegate(Event!T);
	
	protected ListenerDelegate[] listeners;
	protected T payload;
	
	this()
	{
	}
	
	/**
	 * Add a listener callback
	 */
	void addListener(ListenerDelegate listener)
	{
		listeners ~= listener;
	}
	
	/**
	 * Remove a listener callback
	 */
	void removeListener(ListenerDelegate listener)
	{
		foreach (i, l; listeners)
		{
			if (l == listener)
			{
				listeners = listeners[0 .. i] ~ listeners[i + 1 .. $];
				return;
			}
		}
	}
	
	/**
	 * Fire this event, invoking all listeners
	 */
	void fire()
	{
		foreach (listener; listeners)
		{
			listener(this);
		}
	}
	
	/**
	 * Notify listeners with a specific payload
	 * Called by triggers to deliver the payload
	 */
	void notifyWithPayload(T payload)
	{
		this.payload = payload;
		fire();
	}
	
	/**
	 * Get payload (called by listeners)
	 */
	T getPayload() const
	{
		return payload;
	}
}

/**
 * Trigger - Typed trigger implementing ITrigger
 * 
 * Carries an event and payload, implements type-erased notify() interface.
 * Can be executed immediately or scheduled with TriggerScheduler.
 * T: Payload type passed to listeners
 */
class Trigger(T) : ITrigger
{
	Event!T targetEvent;
	T payload;
	
	this(Event!T event, T data)
	{
		this.targetEvent = event;
		this.payload = data;
	}
	
	/**
	 * Notify the linked event with this trigger's payload
	 * Implements ITrigger interface for type-agnostic scheduling
	 */
	void notify()
	{
		targetEvent.notifyWithPayload(payload);
	}
	
	@property Event!T getEvent() { return targetEvent; }
}



/**
 * ScheduledTrigger - Instance of a trigger scheduled for execution
 * 
 * Non-templated node storing ITrigger reference.
 * Intrusive node in circular doubly-linked list.
 * Works with all trigger types regardless of payload.
 */
struct ScheduledTrigger
{
	ITrigger trigger;
	long executeTimeUs;
	ScheduledTrigger* prev;
	ScheduledTrigger* next;
	
	void cancel()
	{
		TriggerScheduler.removeScheduledTrigger(&this);
	}
}

debug(EventJitter)
{
	/// Jitter metrics collected during trigger execution (debug builds only)
	struct JitterMetrics
	{
		long[] deltas;           // Individual delta measurements (µs)
		long minDelta = long.max;
		long maxDelta = long.min;
		long sumDelta = 0;
		ulong triggersProcessed = 0;
		
		/// Get average delta in microseconds
		long avgDelta() const
		{
			return triggersProcessed > 0 ? sumDelta / triggersProcessed : 0;
		}
		
		/// Reset metrics
		void reset()
		{
			deltas = [];
			minDelta = long.max;
			maxDelta = long.min;
			sumDelta = 0;
			triggersProcessed = 0;
		}
	}
	__gshared JitterMetrics jitterMetrics;
}

/**
 * TriggerScheduler - Global timeline managing all scheduled triggers
 * 
 * OWNERSHIP MODEL:
 * ================
 * The scheduler owns COMPLETE execution timing. Callers have zero responsibility:
 * 
 * 1. SCHEDULING (Caller's only job):
 *    - Call scheduleTrigger(trigger, timeUs)
 *    - Scheduler enqueues the trigger
 *    - Returns immediately (fire-and-forget)
 * 
 * 2. EXECUTION (Scheduler's responsibility):
 *    - Scheduler spawns a fiber when queue becomes non-empty
 *    - Fiber calls run(yieldFn) to execute all pending triggers
 *    - run() manages timing, yields, jitter compensation
 *    - Fiber exits when queue empties
 *    - On next scheduleTrigger() with empty queue, new fiber spawns
 * 
 * CONSEQUENCES:
 * =============
 * - Callers cannot intercept execution (no "schedule → do stuff → execute" window)
 * - Callers cannot prevent execution via clear() after scheduling
 * - Timing is entirely scheduler-controlled, independent of caller context
 * - Multiple fibers may run in parallel if scheduleTrigger is called from different contexts
 * 
 * IMPLEMENTATION:
 * ===============
 * Single-threaded, microsecond precision event execution.
 * Uses circular doubly-linked list for O(1) removal and efficient traversal.
 * Type-agnostic: works with all trigger types through ITrigger interface.
 * 
 * Runs as a fiber/coroutine: executes triggers on time with cooperative yields.
 * Fiber lifecycle: spawned on demand, dies when queue empties, respawned on next schedule.
 */
static class TriggerScheduler
{
	private static ScheduledTrigger* head;
	static immutable long ANTI_JITTER_FACTOR = 4;  // Divisor for jitter compensation convergence
	
	/**
	 * Schedule a trigger for execution at an absolute time
	 * 
	 * Fire-and-forget API: caller enqueues, scheduler manages execution.
	 * If queue was empty, spawns a fiber to run the scheduler loop.
	 * Fiber executes all pending triggers, then exits.
	 * 
	 * Scheduler owns all aspects of execution timing and fiber lifecycle.
	 * 
	 * Returns: ScheduledTrigger* for reference (can call cancel() on it)
	 * Side effects: May spawn a fiber that continues to run asynchronously
	 */
	static ScheduledTrigger* scheduleTrigger(ITrigger trigger, long executeTimeUs)
	{
		bool wasEmpty = (head == null);
		
		ScheduledTrigger* scheduled = new ScheduledTrigger();
		scheduled.trigger = trigger;
		scheduled.executeTimeUs = executeTimeUs;
		scheduled.prev = null;
		scheduled.next = null;
		
		insertNodeSorted(scheduled);
		
		// Spawn fiber if pool was empty (became non-empty after insertion)
		if (wasEmpty)
		{
			Fiber schedulerFiber = new Fiber(() {
				TriggerScheduler.executeScheduled();
			});
			schedulerFiber.call();  // Start immediately
		}
		
		return scheduled;
	}
	
	/**
	 * Schedule a trigger with a delay from now
	 */
	static ScheduledTrigger* scheduleTrigger(ITrigger trigger, long delayUs, bool isDelay)
	{
		long executeTimeUs = TimeUtils.currTimeUs() + delayUs;
		// Note: The overload above handles fiber resumption
		return scheduleTrigger(trigger, executeTimeUs);
	}
	
	/**
	 * Remove a scheduled trigger from the timeline
	 */
	static void removeScheduledTrigger(ScheduledTrigger* node)
	{
		if (node == null || head == null)
			return;
		
		if (node.next == node)
		{
			// Only node in list
			head = null;
		}
		else
		{
			// Unlink the node
			node.prev.next = node.next;
			node.next.prev = node.prev;
			
			if (head == node)
				head = node.next;
		}
		
		destroy(node);
	}
	
	/**
	 * Insert a node into sorted position (ascending by executeTimeUs)
	 * Walks backwards from tail for O(1) insertion in typical use case
	 */
	private static void insertNodeSorted(ScheduledTrigger* node)
	{
		if (head == null)
		{
			// First node
			head = node;
			node.prev = node;
			node.next = node;
			return;
		}
		
		// Walk backwards from tail, comparing with new node's executeTime
		ScheduledTrigger* pos = head.prev;  // Start at tail
		
		// Find insertion point: first node with executeTimeUs <= new node's time
		while (pos != head && pos.executeTimeUs > node.executeTimeUs)
		{
			pos = pos.prev;
		}
		
		// Now pos is either head (new node should be first) or a node with executeTimeUs <= new node's time
		if (pos == head && head.executeTimeUs > node.executeTimeUs)
		{
			// New node is earliest, insert before head
			node.next = head;
			node.prev = head.prev;
			head.prev.next = node;
			head.prev = node;
			head = node;  // New head
		}
		else
		{
			// Insert after pos
			node.next = pos.next;
			node.prev = pos;
			pos.next.prev = node;
			pos.next = node;
		}
	}
	
	/**
	 * Process next ready trigger if available
	 * Since list is sorted, head is always the next trigger to execute
	 */
	static void processReady()
	{
		if (head == null)
			return;
		
		long currentTimeUs = TimeUtils.currTimeUs();
		
		if (head.executeTimeUs <= currentTimeUs)
		{
			// Head is ready, execute and remove
			head.trigger.notify();
			removeScheduledTrigger(head);
		}
	}
	
	/**
	 * Process all pending triggers until list is empty
	 */
	static void processAll()
	{
		while (head != null)
		{
			processReady();
		}
	}
	
	/**
	 * Check if there are pending triggers
	 */
	static bool hasPendingTriggers()
	{
		return head != null;
	}
	
	/**
	 * Get next trigger's execution time (head of sorted list)
	 */
	static long nextTriggerTimeUs()
	{
		if (head == null)
			return long.max;
		return head.executeTimeUs;
	}
	
	/**
	 * Clear all pending triggers
	 */
	static void clear()
	{
		while (head != null)
		{
			ScheduledTrigger* next = head.next;
			removeScheduledTrigger(head);
		}
		head = null;
	}
	
	/**
	 * Internal: Busy-spin yield for microsecond precision
	 * Spins until target time is reached.
	 */
	private static void yieldUntil(long delayUs)
	{
		if (delayUs > 0)
		{
			long targetUs = TimeUtils.currTimeUs() + delayUs;
			while (TimeUtils.currTimeUs() < targetUs) { }
		}
	}
	
	/**
	 * SCHEDULER'S EXECUTION FIBER - Internal responsibility
	 * 
	 * Called by spawned fiber to execute all pending triggers on time.
	 * Scheduler owns complete control over fiber lifecycle and yielding behavior.
	 * This is where timing precision and jitter compensation happen.
	 * 
	 * ALGORITHM:
	 * 1. Loop while queue is non-empty:
	 *    2. Calculate delay: nextTriggerTime - now
	 *    3. Apply jitter compensation: yield(delay - offset)
	 *    4. Execute next trigger, measure actual execution time
	 *    5. Update offset: first trigger sets directly, rest converge via delta/FACTOR
	 *    6. Remove trigger from queue and repeat
	 * 
	 * JITTER COMPENSATION:
	 * Predictive offset accumulation based on actual vs scheduled execution time.
	 * First trigger directly sets offset to measured delta.
	 * Subsequent triggers converge exponentially: offset += delta / ANTI_JITTER_FACTOR
	 * Converges to near-zero microsecond precision within ~10-30 triggers.
	 * 
	 * YIELD STRATEGY:
	 * Uses busy-spin yield to achieve microsecond precision.
	 * This is the scheduler's internal concern, not exposed to callers.
	 */
	private static void executeScheduled()
	{
		long offsetUs = 0;  // Accumulated jitter compensation
		bool isFirstTrigger = true;
		
		while (head != null)
		{
			long scheduledTimeUs = head.executeTimeUs;
			long nowUs = TimeUtils.currTimeUs();
			long delayUs = scheduledTimeUs - nowUs;
			
			if (delayUs > 0)
			{
				// Apply accumulated offset as compensation
				long compensatedDelayUs = delayUs - offsetUs;
				yieldUntil(compensatedDelayUs);
			}
			
			// Record actual execution time for jitter measurement
			long actualExecutionTimeUs = TimeUtils.currTimeUs();
			long deltaUs = actualExecutionTimeUs - scheduledTimeUs;
			
			// Update offset: first trigger sets directly, then exponential convergence
			if (isFirstTrigger)
			{
				offsetUs = deltaUs;
				isFirstTrigger = false;
			}
			else
			{
				offsetUs = offsetUs + (deltaUs / ANTI_JITTER_FACTOR);
			}
			
			// Collect jitter metrics (debug builds only)
			debug(EventJitter)
			{
				jitterMetrics.deltas ~= deltaUs;
				jitterMetrics.minDelta = min(jitterMetrics.minDelta, deltaUs);
				jitterMetrics.maxDelta = max(jitterMetrics.maxDelta, deltaUs);
				jitterMetrics.sumDelta += deltaUs;
				jitterMetrics.triggersProcessed++;
			}
			
			// Execute one trigger
			processReady();
		}
	}
}
