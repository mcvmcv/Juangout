Admin.register!(Post;
    list_display = [:body, :author, :created],
    search_fields = [:body, :author__username],
    list_filter = [:created])
