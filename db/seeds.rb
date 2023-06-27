# Post.destroy_all

10.times do |i|
  Post.create({
    title: "Post #{i + 1}",
    body: "words " * 100
  })
end
