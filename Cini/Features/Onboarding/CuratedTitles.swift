import Foundation

/// A hand-picked catalog of instantly-recognizable films AND shows for the
/// onboarding "Seen any of these?" grid — titles almost everyone has seen, so a
/// new user can quickly tap a few and build real taste signal. Verified TMDB ids
/// + poster paths; TV uses the app's negative-id convention so a tapped show
/// ranks correctly.
enum CuratedTitles {
    /// (raw TMDB id, media kind, title, poster path).
    private static let raw: [(id: Int, kind: String, title: String, poster: String)] = [
        // Movies
        (155, "movie", "The Dark Knight", "/qJ2tW6WMUDux911r6m7haRef0WH.jpg"),
        (27205, "movie", "Inception", "/xlaY2zyzMfkhk0HSC5VUwzoZPU1.jpg"),
        (157336, "movie", "Interstellar", "/yQvGrMoipbRoddT0ZR8tPoR7NfX.jpg"),
        (680, "movie", "Pulp Fiction", "/vQWk5YBFWF4bZaofAbv0tShwBvQ.jpg"),
        (496243, "movie", "Parasite", "/7IiTTgloJzvGI1TAYymCfbfl3vT.jpg"),
        (872585, "movie", "Oppenheimer", "/8Gxv8gSFCU0XGDykEGv7zR1n2ua.jpg"),
        (438631, "movie", "Dune", "/gDzOcq0pfeCeqMBwKIJlSmQpjkZ.jpg"),
        (313369, "movie", "La La Land", "/uDO8zWDhfWwoFdKS4fzkUJt0Rf0.jpg"),
        (238, "movie", "The Godfather", "/3bhkrj58Vtu7enYsRolD1fZdja1.jpg"),
        (13, "movie", "Forrest Gump", "/Cw4hIUIAmSYfK9QfaUW5igp9La.jpg"),
        (244786, "movie", "Whiplash", "/7fn624j5lj3xTme2SgiLCeuedmO.jpg"),
        (324857, "movie", "Spider-Man: Into the Spider-Verse", "/iiZZdoQBEYBv6id8su7ImL0oCbD.jpg"),
        (346698, "movie", "Barbie", "/iuFNMS8U5cb6xfzi51Dbkovj7vM.jpg"),
        (361743, "movie", "Top Gun: Maverick", "/n0YuM4f5lvGAP6MAW2kBIzugXnc.jpg"),
        (475557, "movie", "Joker", "/udDclJoHjfjb8Ekgsd4FDteOkCU.jpg"),
        (597, "movie", "Titanic", "/9xjZS2rlVxm8SFx8kPC3aIGCOYQ.jpg"),
        (603, "movie", "The Matrix", "/dXNAPwY7VrqMAo51EKhhCJfaGb5.jpg"),
        (278, "movie", "The Shawshank Redemption", "/9cqNxx0GxF0bflZmeSMuL5tnGzr.jpg"),
        (299534, "movie", "Avengers: Endgame", "/ulzhLuWrPK07P1YkdWQLZnQh1JL.jpg"),
        (98, "movie", "Gladiator", "/wN2xWp1eIwCKOD0BHTcErTBv1Uq.jpg"),
        (8587, "movie", "The Lion King", "/sKCr78MXSLixwmZ8DyJLrpMsd15.jpg"),
        (329, "movie", "Jurassic Park", "/fjTU1Bgh3KJu4aatZil3sofR2zC.jpg"),
        (19995, "movie", "Avatar", "/gKY6q7SjCkAU6FqvqWybDYgUKIF.jpg"),
        (419430, "movie", "Get Out", "/mE24wUCfjK8AoBBjaMjho7Rczr7.jpg"),
        (106646, "movie", "The Wolf of Wall Street", "/kW9LmvYHAaS9iA0tHmZVq8hQYoq.jpg"),
        // TV
        (1396, "tv", "Breaking Bad", "/ztkUQFLlC19CCMYHW9o1zWhJRNq.jpg"),
        (1399, "tv", "Game of Thrones", "/1XS1oqL89opfnbLl8WnZY1O1uJx.jpg"),
        (66732, "tv", "Stranger Things", "/uOOtwVbSr4QDjAGIifLDwpb2Pdl.jpg"),
        (2316, "tv", "The Office", "/7DJKHzAi83BmQrWLrYYOqcoKfhR.jpg"),
        (100088, "tv", "The Last of Us", "/dmo6TYuuJgaYinXBPjrgG9mB5od.jpg"),
        (119051, "tv", "Wednesday", "/36xXlhEpQqVVPuiZhfoQuaY4OlA.jpg"),
        (1668, "tv", "Friends", "/2koX1xLkpTQM4IZebYvKysFW1Nh.jpg"),
        (65494, "tv", "The Crown", "/1M876KPjulVwppEpldhdc8V4o68.jpg"),
        (82856, "tv", "The Mandalorian", "/sWgBv7LV2PRoQgkxwlibdGXKz1S.jpg"),
        (93405, "tv", "Squid Game", "/1QdXdRYfktUSONkl1oD5gc6Be0s.jpg"),
        (71446, "tv", "Money Heist", "/reEMJA1uzscCbkpeRJeTT2bjqUp.jpg"),
        (60574, "tv", "Peaky Blinders", "/vUUqzWa2LnHIVqkaKVlVGkVcZIW.jpg"),
        (42009, "tv", "Black Mirror", "/seN6rRfN0I6n8iDXjlSMk1QjNcq.jpg"),
        (76479, "tv", "The Boys", "/in1R2dDc421JxsoRWaIIAqVI2KE.jpg"),
        (97546, "tv", "Ted Lasso", "/5fhZdwP1DVJ0FyVH6vrFdHwpXIn.jpg"),
        (76331, "tv", "Succession", "/z0XiwdrCQ9yVIr4O0pxzaAYRxdW.jpg"),
        (60059, "tv", "Better Call Saul", "/zjg4jpK1Wp2kiRvtt5ND0kznako.jpg"),
        (19885, "tv", "Sherlock", "/7WTsnHkbA0FaG6R9twfFde0I9hl.jpg"),
        (48891, "tv", "Brooklyn Nine-Nine", "/A3SymGlOHefSKbz1bCOz56moupS.jpg"),
        (71912, "tv", "The Witcher", "/AoGsDM02UVt0npBA8OvpDcZbaMi.jpg"),
    ]

    /// Rankable Movie objects (TV ids negated, minimal fields — `enrich` fills
    /// the rest once a title is actually ranked).
    static let movies: [Movie] = raw.map { item in
        Movie(tmdbID: item.kind == "tv" ? -item.id : item.id,
              mediaKind: item.kind, title: item.title,
              releaseYear: nil, posterPath: item.poster, backdropPath: nil,
              genres: [], certification: nil, runtimeMinutes: nil, director: nil,
              overview: nil, originalLanguage: nil)
    }
}
