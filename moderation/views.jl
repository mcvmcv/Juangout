report_form(data = nothing; instance = nothing) = ModelForm(Report; data, instance, fields = [:reason, :note])

# Reporting a post: a form, then back to the post.
function report(req; id)
    post = get_object_or_404(Post; id, hidden = false)
    if exists(filter(Report; post, reporter = req.user))
        message!(req, :info, "You've already reported this post. Thank you.")
        return redirect(post)
    end
    form = report_form(req.method == "POST" ? req.POST : nothing; instance = Report(; post, reporter = req.user))
    if req.method == "POST" && is_valid(form)
        save!(form)
        message!(req, :success, "Thanks. A moderator will take a look.")
        return redirect(post)
    end
    render(req, "moderation/report.html", Dict("form" => form, "post" => post))
end

# The moderation queue: reported posts, most reported first, each with its open reports.
function queue(req)
    open_reports = Q(reports__resolved = false)
    posts = for_display(filter(Post, open_reports; hidden = false), req.user)   # as posts show everywhere
    posts = annotate(posts; report_count = Count(:reports; filter = open_reports, distinct = true))
    # each post's open reports (and their reporters), all in one more query, as post.open_reports
    posts = prefetch_related(posts, Prefetch(:reports; to_attr = :open_reports,
                                             queryset = select_related(filter(Report; resolved = false), :reporter)))
    posts = order_by(posts, "-report_count", "-created")
    page = get_page(Paginator(posts, 20), get(req.GET, "page", "1"))
    # (templates can't see to_attr lists yet, Juango #263, so hand them over alongside each post)
    rows = [(post = p, reports = p.open_reports) for p in page]
    render(req, "moderation/queue.html", Dict("page_obj" => page, "rows" => rows))
end

# A moderator's decision on a reported post: hide it, or dismiss the reports.
function decide(req; id)
    post = get_object_or_404(Post; id)
    if get(req.POST, "decision", "") == "hide"
        post.hidden = true
        save!(post; update_fields = [:hidden])
        message!(req, :success, "The post is hidden.")
    else
        message!(req, :success, "The reports were dismissed.")
    end
    update!(filter(Report; post, resolved = false); resolved = true, resolved_by = req.user)
    redirect("moderation:queue")
end
