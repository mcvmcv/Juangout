@choices Reason begin
    SPAM = "spam", "Spam or advertising"
    ABUSE = "abuse", "Harassment or abuse"
    OTHER = "other", "Something else"
end

@model struct Report
    post = ForeignKey(Post; on_delete = :CASCADE, related_name = :reports)
    reporter = ForeignKey(USER_MODEL; on_delete = :CASCADE, related_name = :reports_made)
    reason = CharField(max_length = 10, choices = Reason, default = Reason.SPAM)
    note = TextField(max_length = 500, blank = true, verbose_name = "Anything to add?")
    created = DateTimeField(auto_now_add = true)
    resolved = BooleanField(default = false)
    resolved_by = ForeignKey(USER_MODEL; null = true, blank = true, on_delete = :SET_NULL, related_name = :reports_resolved)
    Meta(ordering = ["-created"],
         constraints = [UniqueConstraint(fields = [:post, :reporter], name = "report_once")])
end

Base.show(io::IO, r::Report) = print(io, r.get_reason_display, " (", r.reporter, ")")
