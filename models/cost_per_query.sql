{{ config(materialized='table') }}

with
stop_threshold as (
    select max(end_time) as latest_ts
    from {{ ref('stg_warehouse_metering_history') }}
),

filtered_queries as (
    select
        query_id,
        query_text as original_query_text,
        credits_used_cloud_services,
        warehouse_id,
        warehouse_size is not null as ran_on_warehouse,
        timeadd(
            'millisecond',
            queued_overload_time + compilation_time
            + queued_provisioning_time + queued_repair_time
            + list_external_files_time,
            start_time
        ) as execution_start_time,
        start_time,
        end_time
    from {{ ref('stg_query_history') }}
    where end_time <= (select latest_ts from stop_threshold)
),

hours_list as (
    select
        dateadd(
            'hour',
            '-' || row_number() over (order by seq4() asc),
            dateadd('day', '+1', current_date::timestamp_tz)
        ) as hour_start,
        dateadd('hour', '+1', hour_start) as hour_end
    from table(generator(rowcount => (24 * 730)))
),

-- 1 row per hour a query ran
query_hours as (
    select
        hours_list.hour_start,
        hours_list.hour_end,
        queries.*
    from hours_list
    inner join filtered_queries as queries
        on hours_list.hour_start >= date_trunc('hour', queries.execution_start_time)
            and hours_list.hour_start < queries.end_time
            and queries.ran_on_warehouse
),

query_seconds_per_hour as (
    select
        *,
        datediff('millisecond', greatest(execution_start_time, hour_start), least(end_time, hour_end)) as num_milliseconds_query_ran,
        sum(num_milliseconds_query_ran) over (partition by warehouse_id, hour_start) as total_query_milliseconds_in_hour,
        div0(num_milliseconds_query_ran, total_query_milliseconds_in_hour) as fraction_of_total_query_time_in_hour,
        hour_start as hour
    from query_hours
),

credits_billed_hourly as (
    select
        start_time as hour,
        warehouse_id,
        credits_used_compute,
        credits_used_cloud_services
    from {{ ref('stg_warehouse_metering_history') }}
),

query_cost as (
    select
        query_seconds_per_hour.*,
        credits_billed_hourly.credits_used_compute * daily_rates.effective_rate as actual_warehouse_cost,
        credits_billed_hourly.credits_used_compute * query_seconds_per_hour.fraction_of_total_query_time_in_hour * daily_rates.effective_rate as allocated_compute_cost_in_hour
    from query_seconds_per_hour
    inner join credits_billed_hourly
        on query_seconds_per_hour.warehouse_id = credits_billed_hourly.warehouse_id
            and query_seconds_per_hour.hour = credits_billed_hourly.hour
    inner join {{ ref('daily_rates') }}
        on date(query_seconds_per_hour.start_time) = daily_rates.date
            and daily_rates.service_type = 'COMPUTE'
            and daily_rates.usage_type = 'compute'
),

cost_per_query as (
    select
        query_id,
        any_value(start_time) as start_time,
        any_value(end_time) as end_time,
        any_value(execution_start_time) as execution_start_time,
        sum(allocated_compute_cost_in_hour) as compute_cost,
        any_value(credits_used_cloud_services) as credits_used_cloud_services,
        any_value(ran_on_warehouse) as ran_on_warehouse
    from query_cost
    group by 1
),

credits_billed_daily as (
    select
        date(hour) as date,
        sum(credits_used_compute) as daily_credits_used_compute,
        sum(credits_used_cloud_services) as daily_credits_used_cloud_services,
        greatest(daily_credits_used_cloud_services - daily_credits_used_compute * 0.1, 0) as daily_billable_cloud_services
    from credits_billed_hourly
    group by 1
),

all_queries as (
    select
        query_id,
        start_time,
        end_time,
        execution_start_time,
        compute_cost,
        credits_used_cloud_services,
        ran_on_warehouse
    from cost_per_query

    union all

    select
        query_id,
        start_time,
        end_time,
        execution_start_time,
        0 as compute_cost,
        credits_used_cloud_services,
        ran_on_warehouse
    from filtered_queries
    where
        not ran_on_warehouse
)

select
    all_queries.query_id,
    all_queries.start_time,
    all_queries.end_time,
    all_queries.execution_start_time,
    all_queries.compute_cost,
    -- For the most recent day, which is not yet complete, this calculation won't be perfect.
    -- For example, at 12PM on the latest day, it's possible that cloud credits make up <10% of compute cost, so the queries
    -- from that day are not allocated any cloud_services_cost. The next time the model runs, after we have the full day of data,
    -- this may change if cloud credits make up >10% of compute cost.
    (div0(all_queries.credits_used_cloud_services, credits_billed_daily.daily_credits_used_cloud_services) * credits_billed_daily.daily_billable_cloud_services) * coalesce(daily_rates.effective_rate, current_rates.effective_rate) as cloud_services_cost,
    all_queries.compute_cost + cloud_services_cost as query_cost,
    all_queries.ran_on_warehouse,
    coalesce(daily_rates.currency, current_rates.currency) as currency
from all_queries
inner join credits_billed_daily
    on date(all_queries.start_time) = credits_billed_daily.date
left join {{ ref('daily_rates') }}
    on date(all_queries.start_time) = daily_rates.date
        and daily_rates.service_type = 'COMPUTE'
        and daily_rates.usage_type = 'cloud services'
inner join {{ ref('daily_rates') }} as current_rates
    on current_rates.is_latest_rate
        and current_rates.service_type = 'COMPUTE'
        and current_rates.usage_type = 'cloud services'
order by all_queries.start_time asc
