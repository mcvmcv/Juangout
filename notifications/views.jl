# A context processor: its Dict is added to every template's context. This one gives the
# header its unread count.
unread_notifications(req) =
    is_authenticated(req.user) ? Dict{String,Any}("unread_count" => count(filter(Notification; recipient = req.user, read = false))) :
                                 Dict{String,Any}()

# Your notifications, newest first. Seeing them marks them read.
function notification_list(req)
    qs = select_related(filter(Notification; recipient = req.user), :actor, :post)
    page = get_page(Paginator(qs, 30), get(req.GET, "page", "1"))
    notifications = collect(page)          # fetch this page now, while the unread ones are unread
    update!(filter(Notification; recipient = req.user, read = false); read = true)
    render(req, "notifications/list.html", Dict("notifications" => notifications, "page_obj" => page,
           "paginator" => page.paginator, "is_paginated" => page.paginator.num_pages > 1, "unread_count" => 0))
end
