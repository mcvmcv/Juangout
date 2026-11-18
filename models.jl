# Define your models here, then run:
#     julia --project manage.jl makemigrations
#     julia --project manage.jl migrate

@model struct Note
    title = CharField(max_length = 200)
    body = TextField(blank = true)
    created = DateTimeField(auto_now_add = true)
    Meta(ordering = ["-created"])
end

Base.show(io::IO, n::Note) = print(io, n.title)
