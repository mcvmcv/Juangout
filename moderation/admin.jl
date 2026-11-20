# Admin actions: run on the reports selected in the change list.
function resolve_reports(admin, req, qs)
    n = update!(filter(qs; resolved = false); resolved = true, resolved_by = req.user)
    message!(req, :success, "Resolved $n report$(n == 1 ? "" : "s").")
end

function hide_reported_posts(admin, req, qs)
    post_ids = collect(values_list(qs, :post_id; flat = true))
    update!(filter(Post; id__in = post_ids); hidden = true)
    update!(filter(Report; post_id__in = post_ids, resolved = false); resolved = true, resolved_by = req.user)
    message!(req, :success, "Hid $(length(unique(post_ids))) post(s).")
end

Admin.register!(Report;
    list_display = [:post, :reason, :reporter, :created, :resolved],
    list_filter = [:resolved, :reason],
    search_fields = [:post__body, :reporter__username, :note],
    date_hierarchy = :created,
    readonly_fields = [:post, :reporter, :created],
    actions = [Admin.action(resolve_reports; description = "Mark selected reports resolved"),
               Admin.action(hide_reported_posts; description = "Hide the reported posts", confirm = true,
                            permission = :change)])
